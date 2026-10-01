import AppKit
import CryptoKit
import Darwin
import UniformTypeIdentifiers

enum VerifiedMoveOutcome: Equatable {
    case committed
    case cancelled
    case notCommitted(String)
}

private struct VerifiedMoveError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private struct VerifiedDestination {
    let url: URL
    let digest: Data
}

private struct PromiseWriteResult {
    let destination: VerifiedDestination?
    let error: String?
    let requestedURL: URL?
}

struct VerifiedMoveFileOperations {
    var link: (URL, URL) -> Int32 = { source, destination in
        source.path.withCString { sourcePath in destination.path.withCString { Darwin.link(sourcePath, $0) } }
    }
    var copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    var unlink: (URL) -> Int32 = { $0.path.withCString { Darwin.unlink($0) } }
    var afterSourceUnlinked: (URL) throws -> Void = { _ in }
}

/// Provides a destination file through AppKit's file-promise protocol. The
/// source is removed only after the receiver's completion callback, a byte-for-
/// byte destination check, a final source comparison under file coordination,
/// and a successful coordinated removal.
final class VerifiedFileMove: NSObject, NSFilePromiseProviderDelegate {
    let id = UUID()
    let item: ShelfItem
    private(set) var provider: NSFilePromiseProvider!
    var onFinished: ((UUID, VerifiedMoveOutcome) -> Void)?

    private let store: ShelfStore
    private let fileOperations: VerifiedMoveFileOperations
    private let promiseQueue = OperationQueue()
    private let commitQueue = DispatchQueue(label: "dev.local.drop.verified-move-commit", qos: .utility)
    private let stateQueue = DispatchQueue(label: "dev.local.drop.verified-move-state")
    private var endedOperation: NSDragOperation?
    private var promiseRequested = false
    private var promiseOutcome: PromiseWriteResult?
    private var finalized = false
    private var timeoutScheduled = false

    init(item: ShelfItem, store: ShelfStore, fileOperations: VerifiedMoveFileOperations = VerifiedMoveFileOperations()) throws {
        self.item = item
        self.store = store
        self.fileOperations = fileOperations
        promiseQueue.name = "dev.local.drop.file-promise"
        promiseQueue.maxConcurrentOperationCount = 1
        let type = UTType(filenameExtension: item.url.pathExtension)?.identifier ?? UTType.data.identifier
        super.init()
        provider = NSFilePromiseProvider(fileType: type, delegate: self)
        provider.userInfo = id.uuidString
    }

    static func supportsVerifiedMove(_ url: URL) -> Bool {
        Self.isRegularNonSymlinkFile(url)
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        item.url.lastPathComponent
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        promiseQueue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo destinationURL: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let accepted = stateQueue.sync { () -> Bool in
            guard !finalized, !promiseRequested else { return false }
            promiseRequested = true
            return true
        }
        guard accepted else {
            completionHandler(VerifiedMoveError("This drag was cancelled or already fulfilled."))
            return
        }
        promiseQueue.addOperation { [self] in
            do {
                let written = try writeVerifiedDestination(to: destinationURL)
                completionHandler(nil)
                recordPromiseResult(destination: VerifiedDestination(url: written.url, digest: written.digest), error: nil, requestedURL: destinationURL)
            } catch {
                completionHandler(error)
                recordPromiseResult(destination: nil, error: error.localizedDescription, requestedURL: destinationURL)
            }
        }
    }

    func recordDragEnd(_ operation: NSDragOperation) {
        stateQueue.async { [self] in
            guard !finalized else { return }
            endedOperation = operation
            if operation.isEmpty && promiseOutcome == nil {
                finish(.cancelled, notice: nil)
                return
            }
            scheduleTimeoutIfNeeded()
            finalizeIfReady()
        }
    }

    private func recordPromiseResult(destination: VerifiedDestination?, error: String?, requestedURL: URL?) {
        stateQueue.async { [self] in
            guard !finalized else { return }
            promiseOutcome = PromiseWriteResult(destination: destination, error: error, requestedURL: requestedURL)
            finalizeIfReady()
        }
    }

    private func scheduleTimeoutIfNeeded() {
        guard !timeoutScheduled else { return }
        timeoutScheduled = true
        stateQueue.asyncAfter(deadline: .now() + 45) { [self] in
            guard !finalized else { return }
            finish(.notCommitted("Finder did not finish writing the promised file. The original and shelf reference were kept."),
                   notice: "Move not verified: Finder did not finish writing the destination. The original and shelf reference remain.")
        }
    }

    private func finalizeIfReady() {
        guard !finalized, let operation = endedOperation, let promiseOutcome else { return }
        finalized = true

        guard !operation.isEmpty else {
            completeOnMain(.notCommitted("The destination did not accept the drag."),
                           notice: promiseOutcome.destination == nil ? nil : "The drag was not accepted. The original and shelf reference remain.")
            return
        }
        guard operation.contains(.move) || operation.contains(.copy) else {
            completeOnMain(.notCommitted("The destination returned an unsupported operation."),
                           notice: "Move not verified: the destination returned an unsupported operation. The original and shelf reference remain.")
            return
        }
        guard let destination = promiseOutcome.destination, promiseOutcome.error == nil else {
            let reason = promiseOutcome.error ?? "The destination did not request a file promise."
            let requestedPath = promiseOutcome.requestedURL.map { " Requested destination: \($0.path)." } ?? ""
            completeOnMain(.notCommitted(reason),
                           notice: "Move not verified: \(reason) The original and shelf reference remain.\(requestedPath) NotchPerch will not overwrite an existing file; review the destination before retrying.")
            return
        }

        commitQueue.async { [self] in
            do {
                try removeSourceOnlyAfterVerification(at: destination.url, expectedDigest: destination.digest)
                DispatchQueue.main.async { [self] in
                    store.remove(item)
                    onFinished?(id, .committed)
                }
            } catch {
                let message = "Move not committed: \(error.localizedDescription) The original and shelf reference were kept. The verified destination copy remains at \(destination.url.path); NotchPerch will not overwrite it on retry. Review that copy or retry with a different name."
                DispatchQueue.main.async { [self] in
                    store.setTransferNotice(message, for: item)
                    onFinished?(id, .notCommitted(error.localizedDescription))
                }
            }
        }
    }

    private func completeOnMain(_ outcome: VerifiedMoveOutcome, notice: String?) {
        DispatchQueue.main.async { [self] in
            if let notice { store.setTransferNotice(notice, for: item) }
            onFinished?(id, outcome)
        }
    }

    private func finish(_ outcome: VerifiedMoveOutcome, notice: String?) {
        guard !finalized else { return }
        finalized = true
        completeOnMain(outcome, notice: notice)
    }

    private func writeVerifiedDestination(to destinationURL: URL) throws -> (url: URL, digest: Data) {
        guard Self.isRegularNonSymlinkFile(item.url) else {
            throw VerifiedMoveError("Only regular files can use verified Move.")
        }
        guard destinationURL.standardizedFileURL != item.url.standardizedFileURL else {
            throw CocoaError(.fileWriteFileExists)
        }

        let fileManager = FileManager.default
        let parentURL = destinationURL.deletingLastPathComponent()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        var actualDestination = destinationURL
        var expectedDigest: Data?
        coordinator.coordinate(readingItemAt: item.url, options: .withoutChanges,
                               writingItemAt: parentURL, options: [], error: &coordinationError) { coordinatedSource, coordinatedParent in
            do {
                let coordinatedDestination = coordinatedParent.appendingPathComponent(destinationURL.lastPathComponent)
                guard !fileManager.fileExists(atPath: coordinatedDestination.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                guard Self.isRegularNonSymlinkFile(coordinatedSource) else {
                    throw VerifiedMoveError("The source is no longer a regular file.")
                }
                let stagingURL = coordinatedParent.appendingPathComponent(".Drop-\(UUID().uuidString).partial")
                var stagingOwned = false
                do {
                    try fileManager.copyItem(at: coordinatedSource, to: stagingURL)
                    stagingOwned = true
                    guard fileManager.contentsEqual(atPath: coordinatedSource.path, andPath: stagingURL.path) else {
                        throw VerifiedMoveError("The source changed while Finder's destination was being written.")
                    }
                    let renameResult = stagingURL.path.withCString { sourcePath in
                        coordinatedDestination.path.withCString { destinationPath in
                            renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
                        }
                    }
                    guard renameResult == 0 else { throw posixError("Could not commit the verified destination") }
                    stagingOwned = false
                    guard fileManager.contentsEqual(atPath: coordinatedSource.path, andPath: coordinatedDestination.path) else {
                        throw VerifiedMoveError("The destination bytes do not match the source.")
                    }
                    expectedDigest = try digest(of: coordinatedDestination)
                    actualDestination = coordinatedDestination
                } catch {
                    if stagingOwned { try? fileManager.removeItem(at: stagingURL) }
                    throw error
                }
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
        guard let expectedDigest else { throw VerifiedMoveError("The destination write was not coordinated.") }
        return (actualDestination, expectedDigest)
    }

    private func removeSourceOnlyAfterVerification(at destinationURL: URL, expectedDigest: Data) throws {
        guard FileManager.default.fileExists(atPath: destinationURL.path),
              Self.isRegularNonSymlinkFile(destinationURL) else {
            throw VerifiedMoveError("Finder's destination file is missing or is not a regular file.")
        }

        if !FileManager.default.fileExists(atPath: item.url.path) {
            guard try digest(of: destinationURL) == expectedDigest else {
                throw VerifiedMoveError("The verified destination changed before the source disappeared; the shelf reference was kept.")
            }
            return // The source is already absent; never attempt a second removal.
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(readingItemAt: destinationURL, options: .withoutChanges,
                               writingItemAt: item.url, options: .forDeleting, error: &coordinationError) { coordinatedDestination, coordinatedSource in
            do {
                guard Self.isRegularNonSymlinkFile(coordinatedSource),
                      Self.isRegularNonSymlinkFile(coordinatedDestination),
                      FileManager.default.contentsEqual(atPath: coordinatedSource.path, andPath: coordinatedDestination.path),
                      try digest(of: coordinatedDestination) == expectedDigest else {
                    throw VerifiedMoveError("The source changed or the destination no longer matches; the source was kept.")
                }

                let recoveryURL = coordinatedSource.deletingLastPathComponent()
                    .appendingPathComponent(".drop-recovery-\(UUID().uuidString)")
                try createRecoveryCopy(from: coordinatedSource, to: recoveryURL,
                                       matching: coordinatedDestination, expectedDigest: expectedDigest)

                let unlinkSourceResult = fileOperations.unlink(coordinatedSource)
                guard unlinkSourceResult == 0 else {
                    let error = posixError("Could not remove the source after verification")
                    throw VerifiedMoveError("\(error.localizedDescription). The source remains, and the verified recovery copy was preserved at \(recoveryURL.path).")
                }

                do {
                    try fileOperations.afterSourceUnlinked(coordinatedDestination)
                    guard try digest(of: recoveryURL) == expectedDigest,
                          try digest(of: coordinatedDestination) == expectedDigest else {
                        throw VerifiedMoveError("The destination changed during commit.")
                    }
                } catch {
                    let commitError = error
                    do {
                        try restoreSource(from: recoveryURL, to: coordinatedSource, expectedDigest: expectedDigest)
                    } catch {
                        throw VerifiedMoveError("\(commitError.localizedDescription) The source could not be restored, but the verified recovery copy remains at \(recoveryURL.path): \(error.localizedDescription)")
                    }
                    throw VerifiedMoveError("\(commitError.localizedDescription) The original was restored, and the verified recovery copy was preserved at \(recoveryURL.path).")
                }

                let unlinkRecoveryResult = recoveryURL.path.withCString { Darwin.unlink($0) }
                guard unlinkRecoveryResult == 0 else {
                    let unlinkError = posixError("Could not remove the recovery link")
                    do {
                        try restoreSource(from: recoveryURL, to: coordinatedSource, expectedDigest: expectedDigest)
                    } catch {
                        throw VerifiedMoveError("\(unlinkError.localizedDescription) The verified recovery copy remains at \(recoveryURL.path); source restoration failed: \(error.localizedDescription)")
                    }
                    throw VerifiedMoveError("\(unlinkError.localizedDescription) The original was restored, and the recovery copy remains at \(recoveryURL.path).")
                }
                guard !FileManager.default.fileExists(atPath: coordinatedSource.path) else {
                    throw VerifiedMoveError("A new file appeared at the source path; the shelf reference was kept.")
                }
            } catch {
                operationError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    private func createRecoveryCopy(from source: URL, to recovery: URL, matching destination: URL, expectedDigest: Data) throws {
        let linkResult = fileOperations.link(source, recovery)
        let linkErrorCode = linkResult == 0 ? 0 : errno
        if linkResult == 0 {
            let recoveryOwned = true
            guard try digest(of: recovery) == expectedDigest,
                  FileManager.default.contentsEqual(atPath: recovery.path, andPath: destination.path) else {
                if recoveryOwned { _ = recovery.path.withCString { Darwin.unlink($0) } }
                throw VerifiedMoveError("The recovery link did not match the verified destination; the source was kept.")
            }
            return
        }

        let staging = recovery.deletingLastPathComponent().appendingPathComponent(".drop-rec-\(UUID().uuidString).tmp")
        var stagingOwned = false
        var recoveryOwned = false
        do {
            try fileOperations.copy(source, staging)
            stagingOwned = true
            guard try digest(of: staging) == expectedDigest,
                  FileManager.default.contentsEqual(atPath: staging.path, andPath: destination.path) else {
                throw VerifiedMoveError("The recovery copy did not match the verified destination.")
            }
            let renameResult = staging.path.withCString { stagingPath in
                recovery.path.withCString { recoveryPath in renamex_np(stagingPath, recoveryPath, UInt32(RENAME_EXCL)) }
            }
            guard renameResult == 0 else { throw posixError("Could not publish the recovery copy without overwriting another file") }
            stagingOwned = false
            recoveryOwned = true
            guard try digest(of: recovery) == expectedDigest,
                  FileManager.default.contentsEqual(atPath: recovery.path, andPath: destination.path) else {
                throw VerifiedMoveError("The published recovery copy changed during verification.")
            }
        } catch {
            if stagingOwned { try? FileManager.default.removeItem(at: staging) }
            if recoveryOwned {
                _ = recovery.path.withCString { Darwin.unlink($0) }
            }
            throw VerifiedMoveError("Hard-link recovery was unavailable (\(String(cString: strerror(linkErrorCode)))); the verified-copy fallback failed: \(error.localizedDescription). The original was kept.")
        }
    }

    private func restoreSource(from recovery: URL, to source: URL, expectedDigest: Data) throws {
        guard !FileManager.default.fileExists(atPath: source.path) else {
            throw VerifiedMoveError("The source path is occupied; the recovery copy was preserved at \(recovery.path).")
        }
        let linkResult = fileOperations.link(recovery, source)
        if linkResult == 0 {
            guard try digest(of: source) == expectedDigest else {
                throw VerifiedMoveError("The restored source did not match the recovery copy.")
            }
            return
        }

        let staging = source.deletingLastPathComponent().appendingPathComponent(".drop-res-\(UUID().uuidString).tmp")
        var stagingOwned = false
        do {
            try fileOperations.copy(recovery, staging)
            stagingOwned = true
            guard try digest(of: staging) == expectedDigest else {
                throw VerifiedMoveError("The staged source did not match the recovery copy.")
            }
            let renameResult = staging.path.withCString { stagingPath in
                source.path.withCString { sourcePath in renamex_np(stagingPath, sourcePath, UInt32(RENAME_EXCL)) }
            }
            guard renameResult == 0 else { throw posixError("Could not restore the source without overwriting a new file") }
            stagingOwned = false
            guard try digest(of: source) == expectedDigest else {
                throw VerifiedMoveError("The restored source changed during verification.")
            }
        } catch {
            if stagingOwned { try? FileManager.default.removeItem(at: staging) }
            throw error
        }
    }

    private func posixError(_ action: String) -> NSError {
        let code = errno
        let description = String(cString: strerror(code))
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(action): \(description)"])
    }

    private static func isRegularNonSymlinkFile(_ url: URL) -> Bool {
        var value = stat()
        let result = url.path.withCString { lstat($0, &value) }
        return result == 0 && (value.st_mode & S_IFMT) == S_IFREG
    }

    private func digest(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}
