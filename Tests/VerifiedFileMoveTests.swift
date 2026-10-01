import AppKit
import Darwin
import Foundation

@main
final class VerifiedFileMoveTests: NSObject, NSApplicationDelegate {
    private static let delegate = VerifiedFileMoveTests()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try Self.runSuite()
            try "PASS".write(to: URL(fileURLWithPath: "/private/tmp/drop-verified-move-tests-result.txt"), atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("VerifiedFileMoveTests passed\n".utf8))
            NSApp.terminate(nil)
        } catch {
            try? "FAIL: \(error)".write(to: URL(fileURLWithPath: "/private/tmp/drop-verified-move-tests-result.txt"), atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data("VerifiedFileMoveTests failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func runSuite() throws {
        let domain = "NotchPerch.VerifiedFileMoveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotchPerchVerifiedMoveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ShelfStore(defaults: defaults)

        try testVerifiedPromiseCompletesMove(store: store, root: root)
        try testCancelKeepsSourceAndReference(store: store, root: root)
        try testNoOverwriteOnConflict(store: store, root: root)
        try testSamePathIsRejected(store: store, root: root)
        try testSourceChangePreventsRemoval(store: store, root: root)
        try testAlreadyMovedSourceIsNotRemovedAgain(store: store, root: root)
        try testAcceptedWriteWithNoFinalOperationKeepsSource(store: store, root: root)
        try testRecoveryLinkFailureUsesVerifiedCopyFallback(store: store, root: root)
        try testRecoveryCopyFailureKeepsSourceAndMakesRetrySafe(store: store, root: root)
        try testSourceRemovalFailureKeepsVerifiedRecoveryCopy(store: store, root: root)
        try testRollbackRestoresSourceAndKeepsRecoveryCopy(store: store, root: root)
        try testLongAndUnicodeNamesUseBoundedRecoveryNames(store: store, root: root)

        let reloaded = ShelfStore(defaults: defaults)
        expect(!reloaded.items.contains(where: { $0.url.lastPathComponent == "success.txt" }), "committed move removes persisted shelf reference")
        for name in ["cancel.txt", "conflict.txt", "same-path.txt", "changed.txt", "cancel-after-write.txt", "recovery-copy-fail.txt", "recovery-unlink-fail.txt", "rollback.txt"] {
            expect(reloaded.items.contains(where: { $0.url.lastPathComponent == name }), "uncommitted \(name) reference persists")
        }
    }

    private static func testVerifiedPromiseCompletesMove(store: ShelfStore, root: URL) throws {
        let source = try fixture("success.txt", contents: "source bytes", in: root)
        let destination = root.appendingPathComponent("success-destination.txt")
        let item = ShelfItem(url: source)
        store.add([source])
        let tx = try VerifiedFileMove(item: item, store: store)
        let outcome = OutcomeBox()
        tx.onFinished = { _, value in outcome.value = value }
        tx.recordDragEnd(.copy) // Finder file promises materialize a copy; NotchPerch commits Move only after verification.
        try requestPromise(tx, to: destination)
        waitForOutcome(outcome)
        expect(outcome.value == .committed, "verified promise commits move")
        expect(!exists(source) && exists(destination), "success leaves destination and removes source")
        expect(contents(destination) == "source bytes", "destination bytes verified")
        expect(!store.items.contains(item), "success removes shelf reference")
    }

    private static func testCancelKeepsSourceAndReference(store: ShelfStore, root: URL) throws {
        let source = try fixture("cancel.txt", contents: "keep me", in: root)
        let item = ShelfItem(url: source)
        store.add([source])
        let tx = try VerifiedFileMove(item: item, store: store)
        let outcome = OutcomeBox()
        tx.onFinished = { _, value in outcome.value = value }
        tx.recordDragEnd([])
        waitForOutcome(outcome)
        expect(outcome.value == .cancelled && exists(source) && store.items.contains(item), "cancel keeps source and reference")
    }

    private static func testNoOverwriteOnConflict(store: ShelfStore, root: URL) throws {
        let source = try fixture("conflict.txt", contents: "original", in: root)
        let destination = try fixture("conflict-destination.txt", contents: "existing destination", in: root)
        let item = ShelfItem(url: source)
        store.add([source])
        let tx = try VerifiedFileMove(item: item, store: store)
        let outcome = OutcomeBox()
        tx.onFinished = { _, value in outcome.value = value }
        let promiseError = requestPromiseError(tx, to: destination)
        expect(promiseError != nil, "destination conflict fails promise")
        tx.recordDragEnd(.move)
        waitForOutcome(outcome)
        expect(outcome.value != .committed && contents(source) == "original", "conflict keeps original source")
        expect(contents(destination) == "existing destination" && store.items.contains(item), "conflict does not overwrite destination or remove reference")
    }

    private static func testSamePathIsRejected(store: ShelfStore, root: URL) throws {
        let source = try fixture("same-path.txt", contents: "same path", in: root)
        let item = ShelfItem(url: source)
        store.add([source])
        let tx = try VerifiedFileMove(item: item, store: store)
        let outcome = OutcomeBox()
        tx.onFinished = { _, value in outcome.value = value }
        expect(requestPromiseError(tx, to: source) != nil, "same-path promise rejected")
        tx.recordDragEnd(.move)
        waitForOutcome(outcome)
        expect(outcome.value != .committed && contents(source) == "same path" && store.items.contains(item), "same path preserves source and reference")
    }

    private static func testSourceChangePreventsRemoval(store: ShelfStore, root: URL) throws {
        let source = try fixture("changed.txt", contents: "before drag", in: root)
        let destination = root.appendingPathComponent("changed-destination.txt")
        let item = ShelfItem(url: source)
        store.add([source])
        let tx = try VerifiedFileMove(item: item, store: store)
        let outcome = OutcomeBox()
        tx.onFinished = { _, value in outcome.value = value }
        try requestPromise(tx, to: destination)
        try Data("edited during drag".utf8).write(to: source)
        tx.recordDragEnd(.move)
        waitForOutcome(outcome)
        expect(outcome.value != .committed && contents(source) == "edited during drag", "changed source is retained")
        expect(contents(destination) == "before drag" && store.items.contains(item), "destination copy and shelf reference remain for review")
    }

    private static func testAlreadyMovedSourceIsNotRemovedAgain(store: ShelfStore, root: URL) throws {
        let source = try fixture("already-moved.txt", contents: "preserved data", in: root)
        let destination = root.appendingPathComponent("already-moved-destination.txt")
        let externalLocation = root.appendingPathComponent("already-moved-elsewhere.txt")
        let item = ShelfItem(url: source)
        store.add([source])
        let tx = try VerifiedFileMove(item: item, store: store)
        let outcome = OutcomeBox()
        tx.onFinished = { _, value in outcome.value = value }
        try requestPromise(tx, to: destination)
        try FileManager.default.moveItem(at: source, to: externalLocation) // Fixture simulates an external move before finalization.
        tx.recordDragEnd(.move)
        waitForOutcome(outcome)
        expect(outcome.value == .committed, "verified destination completes when source is already absent")
        expect(exists(externalLocation) && exists(destination) && !exists(source), "already moved data and verified destination both remain")
        expect(!store.items.contains(item), "verified destination clears stale reference")
    }

    private static func testAcceptedWriteWithNoFinalOperationKeepsSource(store: ShelfStore, root: URL) throws {
        let source = try fixture("cancel-after-write.txt", contents: "still original", in: root)
        let destination = root.appendingPathComponent("cancel-after-write-destination.txt")
        let item = ShelfItem(url: source)
        store.add([source])
        let tx = try VerifiedFileMove(item: item, store: store)
        let outcome = OutcomeBox()
        tx.onFinished = { _, value in outcome.value = value }
        try requestPromise(tx, to: destination)
        tx.recordDragEnd([])
        waitForOutcome(outcome)
        expect(outcome.value != .committed && exists(source) && exists(destination), "missing final acceptance never removes source")
        expect(store.items.contains(item), "missing final acceptance keeps reference")
    }

    private static func testRecoveryLinkFailureUsesVerifiedCopyFallback(store: ShelfStore, root: URL) throws {
        let source = try fixture("recovery-fallback.txt", contents: "backup by verified copy", in: root)
        let destination = root.appendingPathComponent("recovery-fallback-destination.txt")
        let item = ShelfItem(url: source)
        store.add([source])
        var operations = VerifiedMoveFileOperations()
        operations.link = { _, _ in errno = EPERM; return -1 }
        let tx = try VerifiedFileMove(item: item, store: store, fileOperations: operations)
        let outcome = OutcomeBox()
        tx.onFinished = { _, value in outcome.value = value }
        tx.recordDragEnd(.move)
        try requestPromise(tx, to: destination)
        waitForOutcome(outcome)
        expect(outcome.value == .committed && !exists(source), "hard-link failure falls back to a committed verified copy")
        expect(contents(destination) == "backup by verified copy", "fallback destination bytes remain exact")
        expect(!store.items.contains(item), "successful fallback removes the persisted shelf reference")
        let successfulFallbackRecoveryFiles = try recoveryFiles(in: root)
        expect(successfulFallbackRecoveryFiles.isEmpty, "successful fallback cleans up its temporary recovery file")
    }

    private static func testRecoveryCopyFailureKeepsSourceAndMakesRetrySafe(store: ShelfStore, root: URL) throws {
        let source = try fixture("recovery-copy-fail.txt", contents: "source must survive", in: root)
        let destination = root.appendingPathComponent("recovery-copy-fail-destination.txt")
        let item = ShelfItem(url: source)
        store.add([source])
        var operations = VerifiedMoveFileOperations()
        operations.link = { _, _ in errno = EPERM; return -1 }
        operations.copy = { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [NSLocalizedDescriptionKey: "fixture recovery copy failure"]) }
        let tx = try VerifiedFileMove(item: item, store: store, fileOperations: operations)
        let outcome = OutcomeBox()
        tx.onFinished = { _, value in outcome.value = value }
        tx.recordDragEnd(.move)
        try requestPromise(tx, to: destination)
        waitForOutcome(outcome)
        expect(outcome.value != .committed && contents(source) == "source must survive", "failed recovery fallback never removes the source")
        expect(exists(destination) && store.items.contains(item), "failed commit keeps destination copy and shelf reference for review")
        let failedFallbackRecoveryFiles = try recoveryFiles(in: root)
        expect(failedFallbackRecoveryFiles.isEmpty, "failed fallback leaves no partial recovery copy")
        expect(store.transferNotices[item.identity]?.contains(destination.path) == true, "failure notice identifies the verified destination copy")
        expect(store.transferNotices[item.identity]?.contains("will not overwrite") == true, "failure notice warns that retry will not overwrite or duplicate")

        let retry = try VerifiedFileMove(item: item, store: store)
        let retryOutcome = OutcomeBox()
        retry.onFinished = { _, value in retryOutcome.value = value }
        expect(requestPromiseError(retry, to: destination) != nil, "retry detects the retained destination conflict")
        retry.recordDragEnd(.move)
        waitForOutcome(retryOutcome)
        expect(contents(source) == "source must survive" && contents(destination) == "source must survive", "retry neither overwrites nor duplicates either copy")
        expect(store.items.contains(item), "conflicting retry keeps the shelf reference")
    }

    private static func testRollbackRestoresSourceAndKeepsRecoveryCopy(store: ShelfStore, root: URL) throws {
        let source = try fixture("rollback.txt", contents: "original rollback bytes", in: root)
        let destination = root.appendingPathComponent("rollback-destination.txt")
        let item = ShelfItem(url: source)
        store.add([source])
        var operations = VerifiedMoveFileOperations()
        operations.afterSourceUnlinked = { destination in try Data("changed at commit boundary".utf8).write(to: destination) }
        let tx = try VerifiedFileMove(item: item, store: store, fileOperations: operations)
        let outcome = OutcomeBox()
        tx.onFinished = { _, value in outcome.value = value }
        tx.recordDragEnd(.move)
        try requestPromise(tx, to: destination)
        waitForOutcome(outcome)
        expect(outcome.value != .committed, "changed destination aborts the transaction")
        expect(contents(source) == "original rollback bytes", "rollback restores the original source")
        expect(contents(destination) == "changed at commit boundary", "rollback does not rewrite the changed destination")
        let retainedRecoveryFiles = try recoveryFiles(in: root)
        expect(retainedRecoveryFiles.contains(where: { contents($0) == "original rollback bytes" }), "verified recovery copy is retained after rollback")
        expect(store.items.contains(item), "rollback retains the shelf reference")
    }

    private static func testSourceRemovalFailureKeepsVerifiedRecoveryCopy(store: ShelfStore, root: URL) throws {
        let source = try fixture("recovery-unlink-fail.txt", contents: "keep both verified copies", in: root)
        let destination = root.appendingPathComponent("recovery-unlink-fail-destination.txt")
        let item = ShelfItem(url: source)
        store.add([source])
        var operations = VerifiedMoveFileOperations()
        operations.unlink = { url in
            guard url.standardizedFileURL.path == source.standardizedFileURL.path else {
                return url.path.withCString { Darwin.unlink($0) }
            }
            errno = EPERM
            return -1
        }
        let tx = try VerifiedFileMove(item: item, store: store, fileOperations: operations)
        let outcome = OutcomeBox()
        tx.onFinished = { _, value in outcome.value = value }
        tx.recordDragEnd(.move)
        try requestPromise(tx, to: destination)
        waitForOutcome(outcome)
        expect(outcome.value != .committed, "source unlink failure does not commit the move")
        expect(contents(source) == "keep both verified copies" && contents(destination) == "keep both verified copies", "source and verified destination both remain")
        let backups = try recoveryFiles(in: root)
        expect(backups.count == 1 && contents(backups[0]) == "keep both verified copies", "recovery copy is preserved when source removal fails")
        expect(store.items.contains(item), "failed source removal keeps the shelf reference")
    }

    private static func testLongAndUnicodeNamesUseBoundedRecoveryNames(store: ShelfStore, root: URL) throws {
        let names = [String(repeating: "a", count: 240) + ".txt", String(repeating: "é", count: 120) + ".txt"]
        for (index, name) in names.enumerated() {
            expect(name.lengthOfBytes(using: .utf8) >= 244 && name.lengthOfBytes(using: .utf8) < 255, "fixture filename is near the filesystem name limit")
            let source = try fixture(name, contents: "long name payload \(index)", in: root)
            let destination = root.appendingPathComponent("destination-\(index)").appendingPathComponent(name)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let item = ShelfItem(url: source)
            store.add([source])
            var operations = VerifiedMoveFileOperations()
            operations.link = { _, _ in errno = EPERM; return -1 }
            let tx = try VerifiedFileMove(item: item, store: store, fileOperations: operations)
            let outcome = OutcomeBox()
            tx.onFinished = { _, value in outcome.value = value }
            tx.recordDragEnd(.move)
            try requestPromise(tx, to: destination)
            waitForOutcome(outcome)
            expect(outcome.value == .committed && !exists(source) && exists(destination), "near-limit filename moves successfully using a bounded recovery name")
            expect(contents(destination) == "long name payload \(index)", "near-limit destination payload remains exact")
            expect(!store.items.contains(item), "successful long filename move clears its reference")
        }
    }

    private static func requestPromise(_ tx: VerifiedFileMove, to destination: URL) throws {
        if let error = requestPromiseError(tx, to: destination) {
            FileHandle.standardError.write(Data("promise_throw=\(error) details=\((error as NSError).userInfo)\n".utf8))
            throw error
        }
    }

    private static func requestPromiseError(_ tx: VerifiedFileMove, to destination: URL) -> Error? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Error?
        tx.filePromiseProvider(tx.provider, writePromiseTo: destination) { error in
            result = error
            semaphore.signal()
        }
        let deadline = Date().addingTimeInterval(15)
        var signaled = semaphore.wait(timeout: .now()) == .success
        while !signaled && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
            signaled = semaphore.wait(timeout: .now()) == .success
        }
        guard signaled else {
            return VerifiedMoveErrorForTest.timeout
        }
        return result
    }

    private static func waitForOutcome(_ outcome: OutcomeBox) {
        let deadline = Date().addingTimeInterval(15)
        while outcome.value == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
        expect(outcome.value != nil, "transfer completion callback arrives")
    }

    private static func fixture(_ name: String, contents: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private static func recoveryFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".drop-recovery-") }
    }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private static func contents(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError("Failed: \(message)") }
    }
}

private final class OutcomeBox {
    var value: VerifiedMoveOutcome?
}

private enum VerifiedMoveErrorForTest: Error {
    case timeout
}
