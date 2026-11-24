import FileProvider
import UniformTypeIdentifiers

/// 진행률 시험용 File Provider 확장.
/// 실제 서버 대신 가짜 파일을 정해진 속도로 천천히 넘겨주며 Progress 를 갱신한다.
/// 파일 앱이 내려받기·올리기 진행을 어떻게 그리는지 보는 것이 목적이다.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    /// 흉내 내는 전송 속도 (바이트/초)
    static let speed: Int64 = 20 * 1024 * 1024
    /// 올리기는 더 천천히 (진행 표시를 오래 보기 위해)
    static let uploadSpeed: Int64 = 5 * 1024 * 1024
    static let chunk: Int64 = 1024 * 1024

    let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {}

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if let item = Catalog.shared.item(identifier) {
            completionHandler(item, nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        guard let item = Catalog.shared.item(itemIdentifier), let size = item.documentSize?.int64Value else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        let progress = Progress(totalUnitCount: size)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        DispatchQueue.global(qos: .userInitiated).async {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: url) else {
                completionHandler(nil, nil, NSFileProviderError(.cannotSynchronize))
                return
            }
            let block = Data(count: Int(Self.chunk))
            var done: Int64 = 0
            while done < size {
                if progress.isCancelled {
                    try? handle.close()
                    try? FileManager.default.removeItem(at: url)
                    completionHandler(nil, nil, CocoaError(.userCancelled))
                    return
                }
                let n = min(Self.chunk, size - done)
                handle.write(n == Self.chunk ? block : block.prefix(Int(n)))
                done += n
                progress.completedUnitCount = done
                Thread.sleep(forTimeInterval: Double(n) / Double(Self.speed))
            }
            try? handle.close()
            completionHandler(url, item, nil)
        }
        return progress
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let isFolder = itemTemplate.contentType == .folder
        let size: Int64 = url.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value } ?? 0
        let progress = Progress(totalUnitCount: max(size, 1))
        DispatchQueue.global(qos: .userInitiated).async {
            var done: Int64 = 0
            while done < size {
                if progress.isCancelled {
                    completionHandler(nil, [], false, CocoaError(.userCancelled))
                    return
                }
                let n = min(Self.chunk, size - done)
                done += n
                progress.completedUnitCount = done
                Thread.sleep(forTimeInterval: Double(n) / Double(Self.uploadSpeed))
            }
            let item = Catalog.shared.add(name: itemTemplate.filename, parent: itemTemplate.parentItemIdentifier,
                                          size: isFolder ? nil : size, folder: isFolder)
            completionHandler(item, [], false, nil)
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let updated = Catalog.shared.update(item, fields: changedFields)
        completionHandler(updated, [], false, updated == nil ? NSFileProviderError(.noSuchItem) : nil)
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        Catalog.shared.remove(identifier)
        completionHandler(nil)
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        TestEnumerator(container: containerItemIdentifier)
    }
}

final class TestEnumerator: NSObject, NSFileProviderEnumerator {
    let container: NSFileProviderItemIdentifier

    init(container: NSFileProviderItemIdentifier) {
        self.container = container
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        if container != .workingSet {
            observer.didEnumerate(Catalog.shared.children(of: container))
        }
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("0".utf8)))
    }
}
