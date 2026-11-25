import AMSMB2
import AVFoundation
import ImageIO
import FileProvider
import UniformTypeIdentifiers
import os

let log = Logger(subsystem: "com.moimz.iNAS", category: "FileProvider")

/// NAS 서버 하나 = 파일 앱 위치 하나 (도메인 식별자 = 서버 id).
/// 맨 위에는 iNAS 에서 고른 공유만 폴더로 보이고, 그 안은 SMB 폴더를 그대로 보여 준다.
/// 항목 식별자: "공유/경로/이름" (맨 위 = rootContainer, 공유 = "공유").
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    let snapshots: FolderSnapshots
    let smb: SMBConnections

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        smb = SMBConnections(serverID: domain.identifier.rawValue)
        snapshots = FolderSnapshots(domainID: domain.identifier.rawValue)
        super.init()
        ThumbnailRecovery.start(domain: domain.identifier.rawValue)
        Task { [weak self] in
            await self?.removeLegacyLockItems()
            await self?.announceTop()
        }
    }

    /// 확장이 뜰 때마다 고른 공유를 working set 으로 한 번 다시 알린다 (이미 있으면 그대로, 날짜는 새로)
    private func announceTop() async {
        guard let server, !server.shares.isEmpty else { return }
        _ = await smb.refreshShareDates(server.shares)
        let items = server.shares.map { NASItem.folder(id: $0, parent: .rootContainer, name: $0, serverID: server.id) }
        await snapshots.apply(deletes: [], updates: items)
        try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
    }

    /// 잠금 기능을 뺀 뒤 한 번: 예전 빌드가 잠금 폴더에 붙였던 번호 식별자("Book|3")를 지우고
    /// 번호 없는 원래 폴더로 다시 알린다. 끝나면 번호 기록을 지워 다시 하지 않는다.
    private func removeLegacyLockItems() async {
        let id = domain.identifier.rawValue
        let epochKey = "lockEpoch.\(id)"
        guard Shared.defaults.object(forKey: epochKey) != nil else { return }
        let epoch = Shared.defaults.integer(forKey: epochKey)
        // 서버 목록 JSON 에 남은 예전 "locked" 값 (NASServer 에서는 뺐다)
        let raw = (Shared.defaults.data(forKey: "servers")).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
        let locked = raw?.first { $0["id"] as? String == id }?["locked"] as? [String] ?? []
        var updates: [NASItem] = []
        for path in locked {
            let (share, inner) = ItemPath.split(path)
            if inner == "/" {
                updates.append(NASItem.folder(id: share, parent: .rootContainer, name: share, serverID: id))
            } else if let manager = try? await smb.manager(share: share),
                      let attributes = try? await manager.attributesOfItem(atPath: inner) {
                updates.append(NASItem(path: path, attributes: attributes))
            }
        }
        let deletes = locked.flatMap { path in (0...epoch).map { "\(path)|\($0)" } }
        await snapshots.apply(deletes: deletes, updates: updates)
        for key in [epochKey, "unlockedUntil.\(id)", "authRequested.\(id)", "askedFolder.\(id)"] {
            Shared.defaults.removeObject(forKey: key)
        }
        log.notice("예전 잠금 폴더 식별자 정리 \(locked, privacy: .public) 번호 0...\(epoch)")
        try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
    }

    func invalidate() {}

    private var server: NASServer? { ServerStore.server(id: domain.identifier.rawValue) }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if identifier == .rootContainer {
            completionHandler(NASItem.root(name: domain.displayName), nil)
            return Progress()
        }
        if ItemPath.isLegacyMarked(identifier.rawValue) {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        let (share, path) = ItemPath.split(identifier.rawValue)
        if path == "/" {
            completionHandler(NASItem.folder(id: identifier.rawValue, parent: .rootContainer, name: share,
                                              serverID: domain.identifier.rawValue), nil)
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
        // 파일 앱이 폴더를 열 때 고치는 마지막 사용 시각·태그 같은 정보는 NAS 에 둘 곳이 없으니 그냥 받는다
        if changedFields.isDisjoint(with: [.filename, .parentItemIdentifier, .contents]) {
            completionHandler(item, [], false, nil)
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
        if ItemPath.isLegacyMarked(containerItemIdentifier.rawValue) {
            throw NSFileProviderError(.noSuchItem)
        }
        return NASEnumerator(container: containerItemIdentifier, shares: server?.shares ?? [], smb: smb,
                             snapshots: snapshots, manager: NSFileProviderManager(for: domain))
    }

    /// 받은 내용을 넘겨줄 임시 파일 자리. File Provider 전용 임시 폴더에 두어야
    /// 시스템이 복사하지 않고 옮겨 가고, 남은 것도 시스템이 정리한다.
    private func temporaryFileURL() -> URL {
        let directory = (try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL()) ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent(UUID().uuidString)
    }
}

final class NASEnumerator: NSObject, NSFileProviderEnumerator {
    let container: NSFileProviderItemIdentifier
    let shares: [String]
    let smb: SMBConnections
    let snapshots: FolderSnapshots

    private var watcher: Task<Void, Never>?

    init(container: NSFileProviderItemIdentifier, shares: [String], smb: SMBConnections, snapshots: FolderSnapshots,
         manager: NSFileProviderManager?) {
        self.container = container
        self.shares = shares
        self.smb = smb
        self.snapshots = snapshots
        super.init()
        if container != .rootContainer, container != .workingSet {
            watcher = Self.watch(container.rawValue, smb: smb, snapshots: snapshots, manager: manager)
        }
    }

    /// 파일 앱이 폴더를 보고 있는 동안(invalidate 전까지) 10초마다 NAS 를 다시 읽어,
    /// 달라졌으면 working set 으로 알린다 → 맥·다른 기기에서 바꾼 것이 곧 보인다
    private static func watch(_ id: String, smb: SMBConnections, snapshots: FolderSnapshots,
                              manager: NSFileProviderManager?) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
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
            let shares = shares
            Task { [smb] in
                _ = await smb.refreshShareDates(shares)
                let serverID = smb.serverID
                observer.didEnumerate(shares.map {
                    NASItem.folder(id: $0, parent: .rootContainer, name: $0, serverID: serverID)
                })
                observer.finishEnumerating(upTo: nil)
            }
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
            if !deletes.isEmpty { observer.didDeleteItems(withIdentifiers: deletes) }
            if !updates.isEmpty { observer.didUpdate(updates) }
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
    private(set) var generation = 0
    private let file: URL

    init(domainID: String) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        file = caches.appendingPathComponent("listings-\(domainID).json")
        listings = (try? JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: file))) ?? [:]
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("relocked-\(domainID)"))
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

    /// working set 으로 넘길 지우기·넣기를 모은다
    func apply(deletes: [String], updates: [NASItem]) {
        for id in deletes {
            pendingDeletes.insert(id)
            pendingUpdates[id] = nil
        }
        for item in updates {
            pendingUpdates[item.itemIdentifier.rawValue] = item
            pendingDeletes.remove(item.itemIdentifier.rawValue)
        }
        generation += 1
        save()
    }

    /// working set 이 변경을 물을 때 모아 둔 것을 넘기고 비운다
    func drain() -> (updates: [NASItem], deletes: [NSFileProviderItemIdentifier], anchor: Int, more: Bool) {
        defer { pendingUpdates = [:]; pendingDeletes = [] }
        return (Array(pendingUpdates.values), pendingDeletes.map { NSFileProviderItemIdentifier($0) }, generation, false)
    }
}

/// 공유 폴더 날짜 (공유 이름별). 공유 목록은 NAS 에 묻지 않고 바로 그리니, 읽어 둔 날짜를 앱 그룹에 둔다.
enum ShareDates {
    private static let key = "shareDates"

    static func get(_ serverID: String, _ share: String) -> Date? {
        let all = Shared.defaults.dictionary(forKey: "\(key).\(serverID)") as? [String: Double]
        return all?[share].map { Date(timeIntervalSince1970: $0) }
    }

    static func set(_ serverID: String, _ dates: [String: Date]) {
        var all = Shared.defaults.dictionary(forKey: "\(key).\(serverID)") as? [String: Double] ?? [:]
        for (share, date) in dates { all[share] = date.timeIntervalSince1970 }
        Shared.defaults.set(all, forKey: "\(key).\(serverID)")
    }
}

/// 서버의 공유별 SMB 연결 (폴더를 옮길 때마다 로그인하지 않도록 재사용)
actor SMBConnections {
    /// 공유 맨 위 폴더의 바뀐 날짜를 NAS 에서 읽어 둔다 (못 읽은 공유는 빼고)
    func refreshShareDates(_ shares: [String]) async -> Bool {
        var dates: [String: Date] = [:]
        for share in shares {
            guard let manager = try? await manager(share: share),
                  let attributes = try? await manager.attributesOfItem(atPath: "/"),
                  let date = attributes[.contentModificationDateKey] as? Date else { continue }
            if ShareDates.get(serverID, share) != date { dates[share] = date }
        }
        if !dates.isEmpty { ShareDates.set(serverID, dates) }
        return !dates.isEmpty
    }

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
    /// 예전 잠금 기능이 붙인 번호 식별자 ("Book|3", "Book|3/a.pdf"). "|" 는 SMB 이름에 쓸 수 없어 실제 이름과 겹치지 않는다.
    static func isLegacyMarked(_ id: String) -> Bool {
        id.split(separator: "/").contains { part in
            let pieces = part.split(separator: "|", omittingEmptySubsequences: false)
            guard pieces.count > 1, let tail = pieces.last else { return false }
            return !tail.isEmpty && tail.allSatisfy(\.isNumber)
        }
    }

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
    var creationDate: Date? { contentModificationDate }
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
            capabilities = [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsEvicting]
        } else if isFolder {
            capabilities = [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsDeleting, .allowsRenaming, .allowsReparenting, .allowsEvicting]
        } else {
            capabilities = [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming, .allowsReparenting, .allowsEvicting]
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

    /// 공유 폴더. 날짜는 NAS 에서 읽어 둔 공유 맨 위 폴더 날짜 (없으면 비움 → 파일 앱이 1970 으로 그렸다)
    static func folder(id: String, parent: NSFileProviderItemIdentifier, name: String, serverID: String) -> NASItem {
        NASItem(id: NSFileProviderItemIdentifier(id), parent: parent, name: name, isFolder: true, size: nil,
                modified: ShareDates.get(serverID, name), isShare: true)
    }
}

// MARK: - 썸네일

/// 파일 앱 목록·아이콘에 그릴 작은 그림. 원본을 다 받지 않고 만들고, 만든 것은 App Group 썸네일 캐시에 둔다:
/// 0) 캐시 (경로·크기·바뀐 시각이 같으면 그대로)
/// 1) 시놀로지가 만들어 둔 썸네일 (같은 폴더의 @eaDir/<파일 이름>/SYNOFILE_THUMB_*.jpg)
/// 2) 작은 사진은 통째로 받아 줄인다
/// 3) 동영상은 앞부분만 받아 장면을 뽑는다 (AVFoundation, 안 되면 ffmpeg)
extension FileProviderExtension: NSFileProviderThumbnailing {
    static let imageLimit: Int64 = 30 << 20
    static let videoHead: UInt64 = 16 << 20
    /// 캐시에 두는 썸네일 긴 변 (파일 앱이 크기마다 따로 물어도 한 장으로 쓴다)
    static let thumbPixels = 512
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "webm", "ts", "m2ts", "mts",
                                               "mpg", "mpeg", "3gp", "vob", "rmvb", "asf"]

    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize,
                         perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
                         completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let finish = Once()
        // 파일 앱이 기다리다 그만두면 바로 답하되, 만들던 것은 끝까지 만들어 캐시에 둔다 → 다음에 볼 때 바로 나옴
        progress.cancellationHandler = {
            finish.run {
                completionHandler(CocoaError(.userCancelled))
            }
        }
        Task { [smb] in
            await withTaskGroup(of: Void.self) { group in
                for identifier in itemIdentifiers {
                    group.addTask {
                        let data = await ThumbnailJobs.shared.data(for: identifier.rawValue) {
                            await Self.thumbnail(for: identifier.rawValue, smb: smb)
                        }
                        if !finish.done {
                            perThumbnailCompletionHandler(identifier, data, nil)
                            progress.completedUnitCount += 1
                        }
                    }
                }
            }
            finish.run {
                completionHandler(nil)
            }
        }
        return progress
    }

    private static func thumbnail(for id: String, smb: SMBConnections) async -> Data? {
        let (share, path) = ItemPath.split(id)
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let type = UTType(filenameExtension: ext) ?? .data
        let isVideo = videoExtensions.contains(ext) || type.conforms(to: .movie)
        let isImage = !isVideo && type.conforms(to: .image)
        guard isVideo || isImage || type.conforms(to: .pdf),
              let manager = try? await smb.manager(share: share),
              let attributes = try? await manager.attributesOfItem(atPath: path) else { return nil }
        let fileSize = (attributes[.fileSizeKey] as? NSNumber)?.int64Value
        guard let cacheURL = ThumbnailCache.url(serverID: smb.serverID, path: id, size: fileSize,
                                                modified: attributes[.contentModificationDateKey] as? Date, pixels: thumbPixels) else {
            return await make(id: id, path: path, name: name, isVideo: isVideo, isImage: isImage, fileSize: fileSize, manager: manager).data
        }
        // 0) 캐시
        if let data = ThumbnailCache.read(cacheURL) {
            return data
        }
        if ThumbnailCache.isFailed(cacheURL) {
            return nil
        }
        // 지난번에 만들다 확장이 끝났으면(메모리 초과 등) 두 번까지만 더 해 본다
        if ThumbnailCache.beginAttempt(cacheURL, serverID: smb.serverID, path: id) >= 2 {
            ThumbnailCache.endAttempt(cacheURL)
            ThumbnailCache.markFailed(cacheURL)
            ThumbnailFailures.add(serverID: smb.serverID, path: id, reason: "만들다 확장이 여러 번 끝나 포기 (메모리 한도 등)")
            return nil
        }
        let result = await make(id: id, path: path, name: name, isVideo: isVideo, isImage: isImage,
                                fileSize: fileSize, manager: manager)
        ThumbnailCache.endAttempt(cacheURL)
        if let data = result.data {
            ThumbnailCache.write(data, to: cacheURL)
        } else {
            if !result.retryable { ThumbnailCache.markFailed(cacheURL) }
            if let reason = result.reason { ThumbnailFailures.add(serverID: smb.serverID, path: id, reason: reason) }
        }
        return result.data
    }

    /// 썸네일, 그리고 실패했을 때 다음에 다시 해 볼 만한지 (네트워크 문제면 다시, 형식 문제면 포기)
    private static func make(id: String, path: String, name: String, isVideo: Bool, isImage: Bool,
                             fileSize: Int64?, manager: SMB2Manager) async -> (data: Data?, retryable: Bool, reason: String?) {
        let size = CGSize(width: thumbPixels, height: thumbPixels)
        // 1) 시놀로지 썸네일
        let eaDir = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("@eaDir/\(name)")
        for file in ["SYNOFILE_THUMB_XL.jpg", "SYNOFILE_THUMB_M.jpg", "SYNOVIDEO_VIDEO_SCREENSHOT.jpg", "SYNOFILE_THUMB_SM.jpg"] {
            if let data = try? await manager.contents(atPath: (eaDir as NSString).appendingPathComponent(file),
                                                      range: Range<UInt64>?.none, progress: nil), !data.isEmpty {
                return (scaled(data, to: size) ?? data, false, nil)
            }
        }

        // 2) 작은 사진
        if isImage {
            guard (fileSize ?? .max) <= imageLimit else {
                return (nil, false, "사진이 \(imageLimit >> 20)MB 보다 큼")
            }
            guard let data = try? await manager.contents(atPath: path, range: Range<UInt64>?.none, progress: nil) else {
                return (nil, true, "NAS 에서 사진을 받지 못함 (다음에 다시 해 봄)")
            }
            let image = scaled(data, to: size)
            return (image, false, image == nil ? "사진을 열지 못함" : nil)
        }

        // 3) 동영상. 확장의 메모리 한도는 약 20MB 라 큰 영상 정보(moov)를 우리 프로세스에서 풀면 iOS 가 확장을 끝낸다.
        //    mp4 계열은 AVFoundation 에 맡기고(영상 정보 풀기·디코딩을 시스템이 함) 필요한 위치만 SMB 로 읽어 준다.
        //    다른 형식(mkv·avi·wmv…)이나 AVFoundation 이 못 여는 mp4 는 FFmpeg — 단 mp4 는 영상 정보가 작을 때만.
        guard isVideo, let fileSize else { return (nil, false, nil) }
        let ext = (name as NSString).pathExtension.lowercased()
        var avFailure: String?
        if ["mp4", "m4v", "mov", "3gp"].contains(ext) {
            let loader = SMBAssetLoader(manager: manager, path: path, size: fileSize, ext: ext)
            do {
                let image = try await withThrowingTimeout(40) { try await loader.frame(maxPixels: thumbPixels) }
                return (jpeg(image), false, nil)
            } catch {
                loader.cancel()
                avFailure = error.localizedDescription
            }
            let moov = await withTimeout(15) { await Self.moovBox(manager: manager, path: path, fileSize: fileSize) }
            guard let moov, moov.size <= ffmpegMoovLimit else {
                return (nil, false, "AVFoundation 실패(\(avFailure ?? "?")), 영상 정보가 커서(\((moov?.size ?? 0) >> 10)KB) FFmpeg 도 못 씀")
            }
        }
        guard let result = await withTimeout(90, {
            await VideoFrame.ffmpeg(manager: manager, path: path, size: fileSize, maxPixels: thumbPixels)
        }) else {
            return (nil, true, "FFmpeg 가 90초 안에 못 끝냄 (다음에 다시 해 봄)")
        }
        if let image = result.image {
            return (jpeg(image), false, nil)
        }
        let ffmpegReason = "FFmpeg: \(result.reason ?? "장면을 못 뽑음")"
        return (nil, result.retryable, avFailure.map { "AVFoundation: \($0) / \(ffmpegReason)" } ?? ffmpegReason)
    }

    /// FFmpeg 로 풀어도 되는 mp4 영상 정보 크기 (재 보니 3MB 짜리에 확장이 16MB 까지 올라 끝남)
    static let ffmpegMoovLimit: Int64 = 1 << 20

    /// mp4·mov 의 맨 위 상자들을 훑어 moov 위치와 크기 (mdat 를 건너뛰어 뒤쪽까지)
    private static func moovBox(manager: SMB2Manager, path: String, fileSize: Int64) async -> (start: Int64, size: Int64)? {
        var offset: Int64 = 0
        for _ in 0..<16 where offset + 8 <= fileSize {
            guard let header = try? await manager.contents(atPath: path, range: UInt64(offset)..<UInt64(min(fileSize, offset + 16)),
                                                           progress: nil), header.count >= 8 else { return nil }
            let bytes = [UInt8](header)
            var boxSize = Int64(bytes[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let type = String(decoding: bytes[4..<8], as: UTF8.self)
            if boxSize == 1, bytes.count >= 16 { boxSize = Int64(bitPattern: bytes[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }) }
            if boxSize == 0 { boxSize = fileSize - offset }
            guard boxSize >= 8 else { return nil }
            if type == "moov" { return (offset, boxSize) }
            offset += boxSize
        }
        return nil
    }

    private static func scaled(_ data: Data, to size: CGSize) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return jpeg(image)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(target) ? data as Data : nil
    }
}

/// 썸네일 만들기를 한곳에서: 같은 파일은 한 번만, 한 번에 하나씩 (확장 메모리 한도 약 20MB).
/// 맡은 일은 파일 앱이 기다리다 그만둬도 끝까지 해 캐시에 넣는다.
actor ThumbnailJobs {
    static let shared = ThumbnailJobs()
    /// 메모리 한도(약 20MB) 때문에 한 번에 하나씩
    private static let limit = 1
    private var running: [String: Task<Data?, Never>] = [:]
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func data(for id: String, make: @escaping @Sendable () async -> Data?) async -> Data? {
        if let task = running[id] { return await task.value }
        let task = Task<Data?, Never> {
            await self.acquire()
            let data = await make()
            await self.release()
            return data
        }
        running[id] = task
        let data = await task.value
        running[id] = nil
        return data
    }

    private func acquire() async {
        if active < Self.limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            active -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// 한 번만 부르기 (파일 앱에 끝났다고 두 번 답하지 않게)
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var done: Bool { lock.withLock { finished } }

    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { finished = true }
            return !finished
        }
        if first { body() }
    }
}


/// 정해진 시간 안에 안 끝나면 nil (안의 일은 남아 돌아도 기다리지 않는다: 멈춘 SMB 읽기·디코딩이 썸네일 차례를 막지 않게)
func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async -> T?) async -> T? {
    await withCheckedContinuation { continuation in
        let once = Once()
        let work = Task {
            let value = await operation()
            once.run { continuation.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            once.run {
                work.cancel()
                continuation.resume(returning: nil)
            }
        }
    }
}

struct TimeoutError: LocalizedError {
    let seconds: Double
    var errorDescription: String? { "\(Int(seconds))초 넘음" }
}

func withThrowingTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let result: Result<T, Error>? = await withTimeout(seconds) {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
    guard let result else { throw TimeoutError(seconds: seconds) }
    return try result.get()
}


/// 확장이 뜰 때: 지난번에 썸네일을 만들다 확장이 끝난 파일(.trying 표시)을 실패 기록에 남기고,
/// 새 빌드면 지난 실패 표시(.fail·.trying)를 지워 다시 해 보게 한다.
enum ThumbnailRecovery {
    static func start(domain: String) {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let defaults = UserDefaults(suiteName: Shared.appGroup)
        let markers = (ThumbnailCache.root.flatMap {
            FileManager.default.enumerator(at: $0, includingPropertiesForKeys: nil)?.allObjects as? [URL]
        } ?? []).filter { ["trying", "fail"].contains($0.pathExtension) }
        for marker in markers where marker.pathExtension == "trying" {
            if let attempt = ThumbnailCache.attemptMarker(marker), attempt.serverID == domain {
                ThumbnailFailures.add(serverID: attempt.serverID, path: attempt.path,
                                      reason: "만드는 도중 확장이 끝남 (메모리 한도 등, 다음에 다시 해 봄)")
            }
        }
        if defaults?.string(forKey: "thumbnailBuild") != build {
            markers.forEach { try? FileManager.default.removeItem(at: $0) }
            defaults?.set(build, forKey: "thumbnailBuild")
            // 문제 찾을 때 남기던 기록 파일 (이전 빌드)
            if let old = ThumbnailCache.root?.deletingLastPathComponent().appendingPathComponent("thumbnail-trace.log") {
                try? FileManager.default.removeItem(at: old)
            }
        }
    }
}
