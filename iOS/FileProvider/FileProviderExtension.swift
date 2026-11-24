import AMSMB2
import FileProvider
import UniformTypeIdentifiers
import os

let log = Logger(subsystem: "com.moimz.iNAS", category: "FileProvider")

/// NAS 서버 하나 = 파일 앱 위치 하나 (도메인 식별자 = 서버 id).
/// 맨 위에는 iNAS 에서 고른 공유만 폴더로 보이고, 그 안은 SMB 폴더를 그대로 보여 준다.
/// 항목 식별자: "공유/경로/이름" (맨 위 = rootContainer, 공유 = "공유")
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    let snapshots: FolderSnapshots
    let smb: SMBConnections

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        smb = SMBConnections(serverID: domain.identifier.rawValue)
        snapshots = FolderSnapshots(domainID: domain.identifier.rawValue)
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
        let newID = ItemPath.child(of: parent.rawValue, name: ItemPath.nfc(itemTemplate.filename))
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
                    let newID = ItemPath.child(of: item.parentItemIdentifier.rawValue, name: ItemPath.nfc(item.filename))
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
                try await ItemPath.removeTree(manager, path: path)
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
        let serverID = domain.identifier.rawValue
        return NASEnumerator(container: containerItemIdentifier, shares: server?.shares ?? [], smb: smb,
                             snapshots: snapshots, manager: NSFileProviderManager(for: domain),
                             isLockedNow: { path in
                                 guard let server = ServerStore.server(id: serverID) else { return false }
                                 return server.isLocked(path) && !LockState.isUnlocked(server.id)
                             },
                             relock: { [weak self] in self?.hideLockedContents() })
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
        log.debug("잠금 확인 \(path, privacy: .public) 열림=\(LockState.isUnlocked(server.id))")
        if LockState.isUnlocked(server.id) {
            LockState.touch(server.id)
            return nil
        }
        LockState.requestAuth(server.id)
        hideLockedContents()
        return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.notAuthenticated.rawValue,
                       userInfo: [AuthReason.key: AuthReason.lockedFolder])
    }

    /// 다시 잠기면 파일 앱이 기억해 둔 잠금 폴더 안 목록을 지운다 (안 그러면 인증 없이 예전 목록을 그대로 보여 줌)
    func hideLockedContents() {
        guard let server else { return }
        let manager = NSFileProviderManager(for: domain)
        Task { [snapshots] in
            if await snapshots.hide(server.locked) {
                log.notice("잠금 폴더 목록 감춤 \(server.locked, privacy: .public)")
                try? await manager?.signalEnumerator(for: .workingSet)
                // 지운 폴더를 빈 껍데기로 다시 넣는 차례
                try? await Task.sleep(for: .seconds(1))
                try? await manager?.signalEnumerator(for: .workingSet)
            }
        }
    }
}

final class NASEnumerator: NSObject, NSFileProviderEnumerator {
    let container: NSFileProviderItemIdentifier
    let shares: [String]
    let smb: SMBConnections
    let snapshots: FolderSnapshots

    private var watcher: Task<Void, Never>?

    init(container: NSFileProviderItemIdentifier, shares: [String], smb: SMBConnections, snapshots: FolderSnapshots,
         manager: NSFileProviderManager?, isLockedNow: @escaping @Sendable (String) -> Bool, relock: @escaping @Sendable () -> Void) {
        self.container = container
        self.shares = shares
        self.smb = smb
        self.snapshots = snapshots
        super.init()
        if container != .rootContainer, container != .workingSet {
            watcher = Self.watch(container.rawValue, smb: smb, snapshots: snapshots, manager: manager,
                                 isLockedNow: isLockedNow, relock: relock)
        }
    }

    /// 파일 앱이 폴더를 보고 있는 동안(invalidate 전까지) 10초마다 NAS 를 다시 읽어,
    /// 달라졌으면 working set 으로 알린다 → 맥·다른 기기에서 바꾼 것이 곧 보인다
    private static func watch(_ id: String, smb: SMBConnections, snapshots: FolderSnapshots,
                              manager: NSFileProviderManager?, isLockedNow: @escaping @Sendable (String) -> Bool,
                              relock: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                // 보고 있던 잠금 폴더의 시간이 다 되면 목록을 감추고 지켜보기를 멈춘다
                if isLockedNow(id) {
                    relock()
                    return
                }
                if await snapshots.refresh(id, smb: smb) {
                    log.notice("NAS 쪽 변경 발견 \(id, privacy: .public)")
                    try? await manager?.signalEnumerator(for: .workingSet)
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func invalidate() {
        watcher?.cancel()
    }

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
                await snapshots.store(id, entries)
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

    /// 폴더는 늘 "기준점 만료" 로 답해 다시 볼 때 전체를 읽게 하고,
    /// working set 은 폴더를 열 때 모아 둔 NAS 쪽 변경(만들기·고치기·지우기)을 넘긴다
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        guard container == .workingSet else {
            observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            return
        }
        Task {
            let (updates, deletes, generation, more) = await snapshots.drain()
            log.notice("working set 변경 넘김 바뀜=\(updates.count) 지움=\(deletes.count)")
            if !updates.isEmpty { observer.didUpdate(updates) }
            if !deletes.isEmpty { observer.didDeleteItems(withIdentifiers: deletes) }
            observer.finishEnumeratingChanges(upTo: Self.anchor(generation), moreComing: more)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        guard container == .workingSet else {
            completionHandler(NSFileProviderSyncAnchor(Data(String(Date().timeIntervalSince1970).utf8)))
            return
        }
        Task { completionHandler(Self.anchor(await snapshots.generation)) }
    }

    private static func anchor(_ generation: Int) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data("ws-\(generation)".utf8))
    }
}

/// 파일 앱은 한 번 본 폴더를 기억해 두고 다시 묻지 않는다. iOS 는 working set 신호만 받으므로
/// 폴더를 열 때 NAS 목록을 지난번과 견주어 달라진 것만 모아 두고 working set 으로 알린다
/// (맥·다른 기기에서 만들고 지운 것이 보이도록). 지난 목록은 확장이 다시 떠도 남게 캐시 파일에 둔다.
actor FolderSnapshots {
    /// 폴더 id → (이름 → 크기|수정 시각)
    private var listings: [String: [String: String]]
    private var checkedAt: [String: Date] = [:]
    private var pendingUpdates: [String: NASItem] = [:]
    private var pendingDeletes: Set<String> = []
    /// 지운 다음 차례에 다시 넣을 잠금 폴더
    private var readd: [String: NASItem] = [:]
    /// 잠긴 뒤 이미 되돌려 놓은 잠금 폴더
    private var hidden: Set<String> = []
    private(set) var generation = 0
    private let file: URL

    init(domainID: String) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        file = caches.appendingPathComponent("listings-\(domainID).json")
        listings = (try? JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: file))) ?? [:]
    }

    private static func listing(_ entries: [[URLResourceKey: any Sendable]]) -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries {
            guard let name = entry[.nameKey] as? String, !ItemPath.isHidden(name) else { continue }
            let size = (entry[.fileSizeKey] as? NSNumber)?.int64Value ?? -1
            let modified = (entry[.contentModificationDateKey] as? Date)?.timeIntervalSince1970 ?? 0
            result[name] = "\(size)|\(Int(modified))"
        }
        return result
    }

    private func save() {
        if listings.count > 300 { listings = Dictionary(uniqueKeysWithValues: listings.prefix(200).map { ($0.key, $0.value) }) }
        try? JSONEncoder().encode(listings).write(to: file, options: .atomic)
    }

    /// 파일 앱이 목록 전체를 읽어 갔을 때 그 목록을 기억
    func store(_ id: String, _ entries: [[URLResourceKey: any Sendable]]) {
        hidden = hidden.filter { !(id == $0 || id.hasPrefix($0 + "/")) }
        listings[id] = Self.listing(entries)
        checkedAt[id] = Date()
        save()
    }

    /// 폴더를 열 때 NAS 를 다시 읽어 달라진 것을 모아 둔다. 모은 게 있으면 true.
    func refresh(_ id: String, smb: SMBConnections) async -> Bool {
        if let last = checkedAt[id], Date().timeIntervalSince(last) < 3 { return false }
        checkedAt[id] = Date()
        let (share, path) = ItemPath.split(id)
        guard let manager = try? await smb.manager(share: share),
              let entries = try? await manager.contentsOfDirectory(atPath: path) else { return false }
        let now = Self.listing(entries)
        // 지난 목록이 없으면(처음·캐시 지워짐) 지운 건 알 수 없으니 지금 있는 것만 모두 알린다
        let before = listings[id] ?? [:]
        listings[id] = now
        save()
        var found = false
        for entry in entries {
            guard let name = entry[.nameKey] as? String, let sig = now[name], before[name] != sig else { continue }
            let childID = ItemPath.child(of: id, name: name)
            pendingUpdates[childID] = NASItem(path: childID, attributes: entry)
            pendingDeletes.remove(childID)
            found = true
        }
        for name in before.keys where now[name] == nil {
            let childID = ItemPath.child(of: id, name: name)
            pendingDeletes.insert(childID)
            pendingUpdates[childID] = nil
            found = true
        }
        if found { generation += 1 }
        return found
    }

    /// 다시 잠긴 잠금 폴더를 파일 앱에서 "처음 보는 폴더" 로 되돌린다: 폴더를 한 번 지웠다가(안쪽 목록·받은 파일도 같이 빠짐)
    /// 다음 차례에 빈 껍데기로 다시 넣는다. 그러면 파일 앱이 폴더를 열 때 목록을 새로 묻고, 그때 인증을 요구할 수 있다.
    /// 잠긴 뒤 폴더마다 한 번만 한다(다시 열려 목록을 읽으면 store 가 표시를 지움) — 계속 되풀이하지 않도록.
    func hide(_ lockedPaths: [String]) -> Bool {
        var found = false
        for locked in lockedPaths where !hidden.contains(locked) {
            hidden.insert(locked)
            pendingDeletes.insert(locked)
            pendingUpdates[locked] = nil
            let isShare = !locked.contains("/")
            readd[locked] = NASItem(id: NSFileProviderItemIdentifier(locked), parent: ItemPath.parent(of: locked),
                                    name: (locked as NSString).lastPathComponent, isFolder: true, size: nil, modified: nil,
                                    isShare: isShare)
            for key in listings.keys where key == locked || key.hasPrefix(locked + "/") {
                listings[key] = nil
                checkedAt[key] = nil
            }
            found = true
        }
        if found { generation += 1; save() }
        return found
    }

    /// working set 이 변경을 물을 때 모아 둔 것을 넘기고 비운다
    /// 지울 것 가운데 다시 넣을 잠금 폴더가 있으면 이번엔 지우기만 하고 moreComing 으로 곧바로 다음 차례를 받는다
    func drain() -> (updates: [NASItem], deletes: [NSFileProviderItemIdentifier], anchor: Int, more: Bool) {
        if pendingDeletes.isEmpty, pendingUpdates.isEmpty, !readd.isEmpty {
            defer { readd = [:]; generation += 1 }
            return (Array(readd.values), [], generation + 1, false)
        }
        defer { pendingUpdates = [:]; pendingDeletes = [] }
        return (Array(pendingUpdates.values), pendingDeletes.map { NSFileProviderItemIdentifier($0) }, generation, !readd.isEmpty)
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

    /// AMSMB2 의 removeItem 은 폴더 속 파일 경로를 URL 로 만들면서 한글을 NFD 로 바꿔 놓아 NAS 가 '없는 파일' 로 답한다
    /// → 서버가 준 이름 그대로 문자열로 이어 붙여 직접 하나씩 지운다
    static func removeTree(_ manager: SMB2Manager, path: String) async throws {
        let attributes = try await manager.attributesOfItem(atPath: path)
        guard attributes.isDirectory else {
            try await manager.removeFile(atPath: path)
            return
        }
        for entry in try await manager.contentsOfDirectory(atPath: path) {
            guard let name = entry[.nameKey] as? String, name != ".", name != ".." else { continue }
            let childPath = (path.hasSuffix("/") ? path : path + "/") + name
            if (entry[.isDirectoryKey] as? Bool) == true {
                try await removeTree(manager, path: childPath)
            } else {
                try await manager.removeFile(atPath: childPath)
            }
        }
        try await manager.removeDirectory(atPath: path, recursive: false)
    }

    static func child(of parent: String, name: String) -> String {
        parent + "/" + name
    }

    /// 파일 앱이 주는 한글 이름은 NFD(자모 분리)라 그대로 NAS 에 쓰면 맥·윈도에서 열리지 않는다 → 만들거나 바꿀 때 NFC 로
    static func nfc(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
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
