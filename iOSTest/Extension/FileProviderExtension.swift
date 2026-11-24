import AMSMB2
import FileProvider
import UniformTypeIdentifiers

/// NAS 서버 하나 = 파일 앱 위치 하나 (도메인 식별자 = 서버 id).
/// 맨 위에는 iNAS 에서 고른 공유만 폴더로 보이고, 그 안은 SMB 폴더를 그대로 보여 준다.
/// 항목 식별자: "공유/경로/이름" (맨 위 = rootContainer, 공유 = "공유")
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    let smb: SMBConnections

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        smb = SMBConnections(serverID: domain.identifier.rawValue)
        super.init()
    }

    func invalidate() {}

    private var server: NASServer? { ServerStore.server(id: domain.identifier.rawValue) }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if identifier == .rootContainer {
            completionHandler(NASItem.root(name: domain.displayName), nil)
            return Progress()
        }
        let (share, path) = ItemPath.split(identifier.rawValue)
        if path == "/" {
            completionHandler(NASItem.folder(id: share, parent: .rootContainer, name: share), nil)
            return Progress()
        }
        Task {
            do {
                let manager = try await smb.manager(share: share)
                let attributes = try await manager.attributesOfItem(atPath: path)
                completionHandler(NASItem(path: identifier.rawValue, attributes: attributes), nil)
            } catch {
                completionHandler(nil, await smb.mapped(error))
            }
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        if let error = lockError(for: itemIdentifier.rawValue) {
            completionHandler(nil, nil, error)
            return progress
        }
        let (share, path) = ItemPath.split(itemIdentifier.rawValue)
        let url = temporaryFileURL()
        Task {
            do {
                let manager = try await smb.manager(share: share)
                let attributes = try await manager.attributesOfItem(atPath: path)
                // 디스크로 바로 흘려 받는다 (약 1MB 마다 진행 알림, 파일 전체를 메모리에 올리지 않음)
                try await manager.downloadItem(atPath: path, to: url) { bytes, total in
                    progress.totalUnitCount = max(total, 1)
                    progress.completedUnitCount = bytes
                    return !progress.isCancelled
                }
                completionHandler(url, NASItem(path: itemIdentifier.rawValue, attributes: attributes), nil)
            } catch {
                try? FileManager.default.removeItem(at: url)
                completionHandler(nil, nil, progress.isCancelled ? CocoaError(.userCancelled) : await smb.mapped(error))
            }
        }
        return progress
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let parent = itemTemplate.parentItemIdentifier
        guard parent != .rootContainer else {
            // 맨 위(공유 목록)에는 만들 수 없다
            completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize))
            return progress
        }
        let newID = ItemPath.child(of: parent.rawValue, name: itemTemplate.filename)
        if let error = lockError(for: newID) {
            completionHandler(nil, [], false, error)
            return progress
        }
        let (share, path) = ItemPath.split(newID)
        Task {
            do {
                let manager = try await smb.manager(share: share)
                if itemTemplate.contentType == .folder {
                    try await manager.createDirectory(atPath: path)
                } else if let url {
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                    progress.totalUnitCount = max(size, 1)
                    try await manager.uploadItem(at: url, toPath: path) { bytes in
                        progress.completedUnitCount = bytes
                        return !progress.isCancelled
                    }
                }
                let attributes = try await manager.attributesOfItem(atPath: path)
                completionHandler(NASItem(path: newID, attributes: attributes), [], false, nil)
            } catch {
                completionHandler(nil, [], false, progress.isCancelled ? CocoaError(.userCancelled) : await smb.mapped(error))
            }
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let oldID = item.itemIdentifier.rawValue
        if let error = lockError(for: oldID) {
            completionHandler(nil, [], false, error)
            return progress
        }
        let (share, oldPath) = ItemPath.split(oldID)
        Task {
            do {
                let manager = try await smb.manager(share: share)
                var path = oldPath
                var id = oldID
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    // 같은 공유 안에서만 옮긴다
                    let newID = ItemPath.child(of: item.parentItemIdentifier.rawValue, name: item.filename)
                    let (newShare, newPath) = ItemPath.split(newID)
                    guard newShare == share else { throw NSFileProviderError(.cannotSynchronize) }
                    try await manager.moveItem(atPath: oldPath, toPath: newPath)
                    path = newPath
                    id = newID
                }
                if changedFields.contains(.contents), let newContents {
                    let size = (try? FileManager.default.attributesOfItem(atPath: newContents.path)[.size] as? NSNumber)?.int64Value ?? 0
                    progress.totalUnitCount = max(size, 1)
                    try await manager.uploadItem(at: newContents, toPath: path) { bytes in
                        progress.completedUnitCount = bytes
                        return !progress.isCancelled
                    }
                }
                let attributes = try await manager.attributesOfItem(atPath: path)
                completionHandler(NASItem(path: id, attributes: attributes), [], false, nil)
            } catch {
                completionHandler(nil, [], false, await smb.mapped(error))
            }
        }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        if let error = lockError(for: identifier.rawValue) {
            completionHandler(error)
            return Progress()
        }
        let (share, path) = ItemPath.split(identifier.rawValue)
        Task {
            do {
                let manager = try await smb.manager(share: share)
                try await manager.removeItem(atPath: path)
                completionHandler(nil)
            } catch {
                completionHandler(await smb.mapped(error))
            }
        }
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier != .rootContainer, containerItemIdentifier != .workingSet,
           let error = lockError(for: containerItemIdentifier.rawValue) {
            throw error
        }
        return NASEnumerator(container: containerItemIdentifier, shares: server?.shares ?? [], smb: smb)
    }

    /// 받은 내용을 넘겨줄 임시 파일 자리. File Provider 전용 임시 폴더에 두어야
    /// 시스템이 복사하지 않고 옮겨 가고, 남은 것도 시스템이 정리한다.
    private func temporaryFileURL() -> URL {
        let directory = (try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL()) ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent(UUID().uuidString)
    }

    /// 잠금 폴더 안인데 열려 있지 않으면 "인증 필요". 열려 있으면 시간을 늘린다.
    private func lockError(for path: String) -> Error? {
        guard let server, server.isLocked(path) else { return nil }
        if LockState.isUnlocked(server.id) {
            LockState.touch(server.id)
            return nil
        }
        return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.notAuthenticated.rawValue,
                       userInfo: [AuthReason.key: AuthReason.lockedFolder])
    }
}

final class NASEnumerator: NSObject, NSFileProviderEnumerator {
    let container: NSFileProviderItemIdentifier
    let shares: [String]
    let smb: SMBConnections

    init(container: NSFileProviderItemIdentifier, shares: [String], smb: SMBConnections) {
        self.container = container
        self.shares = shares
        self.smb = smb
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        if container == .workingSet {
            observer.finishEnumerating(upTo: nil)
            return
        }
        if container == .rootContainer {
            observer.didEnumerate(shares.map { NASItem.folder(id: $0, parent: .rootContainer, name: $0) })
            observer.finishEnumerating(upTo: nil)
            return
        }
        let id = container.rawValue
        let (share, path) = ItemPath.split(id)
        Task {
            do {
                let manager = try await smb.manager(share: share)
                let entries = try await manager.contentsOfDirectory(atPath: path)
                let items = entries.compactMap { entry -> NASItem? in
                    guard let name = entry[.nameKey] as? String, !ItemPath.isHidden(name) else { return nil }
                    return NASItem(path: ItemPath.child(of: id, name: name), attributes: entry)
                }
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(await smb.mapped(error))
            }
        }
    }

    /// 변경 추적 대신 매번 "기준점 만료" 로 답해, 폴더를 다시 볼 때 목록 전체를 다시 읽게 한다 (시험용 단순화)
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        if container == .workingSet {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
        } else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data(String(Date().timeIntervalSince1970).utf8)))
    }
}

/// 서버의 공유별 SMB 연결 (폴더를 옮길 때마다 로그인하지 않도록 재사용)
actor SMBConnections {
    let serverID: String
    private var managers: [String: SMB2Manager] = [:]

    init(serverID: String) {
        self.serverID = serverID
    }

    func manager(share: String) async throws -> SMB2Manager {
        if let manager = managers[share] { return manager }
        guard let server = ServerStore.server(id: serverID) else { throw NSFileProviderError(.notAuthenticated) }
        var components = URLComponents()
        components.scheme = "smb"
        components.host = server.host
        components.port = server.port
        let credential = URLCredential(user: server.username, password: PasswordStore.password(for: serverID) ?? "",
                                       persistence: .forSession)
        guard let url = components.url, let manager = SMB2Manager(url: url, credential: credential) else {
            throw NSFileProviderError(.serverUnreachable)
        }
        manager.timeout = 15
        try await manager.connectShare(name: share)
        managers[share] = manager
        return manager
    }

    /// libsmb2 오류를 파일 앱 오류로. 로그인·연결 오류면 저장된 연결을 버린다.
    func mapped(_ error: Error) -> Error {
        if error is NSFileProviderError || (error as NSError).domain == NSFileProviderErrorDomain { return error }
        guard let posix = error as? POSIXError else { return error }
        let text = posix.localizedDescription.uppercased()
        if ["LOGON_FAILURE", "WRONG_PASSWORD", "ACCOUNT_"].contains(where: text.contains) || [.EAUTH, .ENEEDAUTH].contains(posix.code) {
            managers.removeAll()
            return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.notAuthenticated.rawValue,
                           userInfo: [AuthReason.key: AuthReason.loginFailed])
        }
        if posix.code == .ENOENT { return NSFileProviderError(.noSuchItem) }
        if [.ENOTCONN, .ECONNRESET, .ECONNREFUSED, .ETIMEDOUT, .EPIPE, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .EPERM].contains(posix.code) {
            managers.removeAll()
            return NSFileProviderError(.serverUnreachable)
        }
        return error
    }
}

enum ItemPath {
    /// "공유/a/b" → ("공유", "/a/b"), "공유" → ("공유", "/")
    static func split(_ id: String) -> (share: String, path: String) {
        let parts = id.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return (parts.first ?? "", "/" + parts.dropFirst().joined(separator: "/"))
    }

    static func child(of parent: String, name: String) -> String {
        parent + "/" + name
    }

    static func parent(of id: String) -> NSFileProviderItemIdentifier {
        guard let slash = id.lastIndex(of: "/") else { return .rootContainer }
        return NSFileProviderItemIdentifier(String(id[..<slash]))
    }

    /// 시놀로지 내부 폴더·숨김 파일은 보이지 않게
    static func isHidden(_ name: String) -> Bool {
        name == "." || name == ".." || name.hasPrefix(".") || name.hasPrefix("@") || name == "#recycle"
    }
}

final class NASItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let contentModificationDate: Date?
    let capabilities: NSFileProviderItemCapabilities
    let itemVersion: NSFileProviderItemVersion

    init(id: NSFileProviderItemIdentifier, parent: NSFileProviderItemIdentifier, name: String,
         isFolder: Bool, size: Int64?, modified: Date?, isShare: Bool = false) {
        itemIdentifier = id
        parentItemIdentifier = parent
        filename = name
        contentType = isFolder ? .folder : (UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)
        documentSize = isFolder ? nil : size.map { NSNumber(value: $0) }
        contentModificationDate = modified
        if isShare {
            capabilities = [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
        } else if isFolder {
            capabilities = [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsDeleting, .allowsRenaming, .allowsReparenting]
        } else {
            capabilities = [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming, .allowsReparenting]
        }
        let version = Data("\(size ?? 0)-\(modified?.timeIntervalSince1970 ?? 0)".utf8)
        itemVersion = NSFileProviderItemVersion(contentVersion: version, metadataVersion: version)
        super.init()
    }

    convenience init(path: String, attributes: [URLResourceKey: any Sendable]) {
        let isFolder = (attributes[.isDirectoryKey] as? Bool) ?? ((attributes[.isDirectoryKey] as? NSNumber)?.boolValue ?? false)
        self.init(id: NSFileProviderItemIdentifier(path), parent: ItemPath.parent(of: path),
                  name: (path as NSString).lastPathComponent, isFolder: isFolder,
                  size: (attributes[.fileSizeKey] as? NSNumber)?.int64Value,
                  modified: attributes[.contentModificationDateKey] as? Date)
    }

    static func root(name: String) -> NASItem {
        NASItem(id: .rootContainer, parent: .rootContainer, name: name, isFolder: true, size: nil, modified: nil, isShare: true)
    }

    static func folder(id: String, parent: NSFileProviderItemIdentifier, name: String) -> NASItem {
        NASItem(id: NSFileProviderItemIdentifier(id), parent: parent, name: name, isFolder: true, size: nil, modified: nil, isShare: true)
    }
}
