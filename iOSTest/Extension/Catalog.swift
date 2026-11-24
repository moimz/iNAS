import FileProvider
import UniformTypeIdentifiers

/// 가짜 서버의 파일 목록 (확장 프로세스 메모리에만 있음 — 시험용)
final class Catalog {
    static let shared = Catalog()

    private let lock = NSLock()
    private var items: [NSFileProviderItemIdentifier: TestItem] = [:]

    private init() {
        let mb: Int64 = 1024 * 1024
        let root = TestItem(id: .rootContainer, parent: .rootContainer, name: "iNAS 시험", size: nil, folder: true)
        items[root.itemIdentifier] = root
        for (name, size) in [("영상-200MB.mov", 200 * mb), ("백업-1GB.zip", 1024 * mb)] {
            let item = TestItem(id: NSFileProviderItemIdentifier(name), parent: .rootContainer, name: name, size: size, folder: false)
            items[item.itemIdentifier] = item
        }
    }

    func item(_ id: NSFileProviderItemIdentifier) -> TestItem? {
        lock.lock(); defer { lock.unlock() }
        return items[id]
    }

    func children(of parent: NSFileProviderItemIdentifier) -> [TestItem] {
        lock.lock(); defer { lock.unlock() }
        return items.values.filter { $0.parentItemIdentifier == parent && $0.itemIdentifier != .rootContainer }
            .sorted { $0.filename < $1.filename }
    }

    func add(name: String, parent: NSFileProviderItemIdentifier, size: Int64?, folder: Bool) -> TestItem {
        let item = TestItem(id: NSFileProviderItemIdentifier(UUID().uuidString), parent: parent, name: name, size: size, folder: folder)
        lock.lock(); defer { lock.unlock() }
        items[item.itemIdentifier] = item
        return item
    }

    func update(_ template: NSFileProviderItem, fields: NSFileProviderItemFields) -> TestItem? {
        lock.lock(); defer { lock.unlock() }
        guard let old = items[template.itemIdentifier] else { return nil }
        let item = TestItem(id: old.itemIdentifier,
                            parent: fields.contains(.parentItemIdentifier) ? template.parentItemIdentifier : old.parentItemIdentifier,
                            name: fields.contains(.filename) ? template.filename : old.filename,
                            size: old.documentSize?.int64Value, folder: old.contentType == .folder)
        items[item.itemIdentifier] = item
        return item
    }

    func remove(_ id: NSFileProviderItemIdentifier) {
        lock.lock(); defer { lock.unlock() }
        items[id] = nil
    }
}

final class TestItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let documentSize: NSNumber?
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let itemVersion: NSFileProviderItemVersion

    init(id: NSFileProviderItemIdentifier, parent: NSFileProviderItemIdentifier, name: String, size: Int64?, folder: Bool) {
        itemIdentifier = id
        parentItemIdentifier = parent
        filename = name
        documentSize = size.map { NSNumber(value: $0) }
        contentType = folder ? .folder : (UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)
        capabilities = folder
            ? [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsDeleting, .allowsRenaming]
            : [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming, .allowsReparenting]
        let v = Data("1".utf8)
        itemVersion = NSFileProviderItemVersion(contentVersion: v, metadataVersion: v)
        super.init()
    }
}
