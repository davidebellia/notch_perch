import Foundation

struct ShelfItem: Equatable {
    let url: URL
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    var identity: String { url.standardizedFileURL.path }
}

final class ShelfStore {
    private let defaults: UserDefaults
    private let defaultsKey: String
    private(set) var items: [ShelfItem] = []
    private(set) var transferNotices: [String: String] = [:]
    var changed: (() -> Void)?

    init(defaults: UserDefaults = .standard, defaultsKey: String = "shelfItemPaths") {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        let paths = defaults.stringArray(forKey: defaultsKey) ?? []
        items = paths.map { ShelfItem(url: URL(fileURLWithPath: $0).standardizedFileURL) }
    }

    func add(_ urls: [URL]) {
        for url in urls {
            let item = ShelfItem(url: url.standardizedFileURL)
            if !items.contains(where: { $0.identity == item.identity }) { items.append(item) }
        }
        persist()
        changed?()
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.identity == item.identity }
        transferNotices.removeValue(forKey: item.identity)
        persist()
        changed?()
    }

    func setTransferNotice(_ message: String, for item: ShelfItem) {
        transferNotices[item.identity] = message
        changed?()
    }

    private func persist() {
        defaults.set(items.map(\.identity), forKey: defaultsKey)
    }
}
