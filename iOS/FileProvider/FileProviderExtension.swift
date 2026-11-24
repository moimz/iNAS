import AMSMB2
import FileProvider
import UniformTypeIdentifiers
import os

let log = Logger(subsystem: "com.moimz.iNAS", category: "FileProvider")

/// NAS 서버 하나 = 파일 앱 위치 하나 (도메인 식별자 = 서버 id).
/// 맨 위에는 iNAS 에서 고른 공유만 폴더로 보이고, 그 안은 SMB 폴더를 그대로 보여 준다.
/// 항목 식별자: "공유/경로/이름" (맨 위 = rootContainer, 공유 = "공유").
/// 잠금 폴더는 이름 뒤에 다시 잠근 번호를 붙인다: "Book|3", 그 안은 "Book|3/a.pdf" (LockMarks)
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    let snapshots: FolderSnapshots
    let smb: SMBConnections

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        smb = SMBConnections(serverID: domain.identifier.rawValue)
        snapshots = FolderSnapshots(domainID: domain.identifier.rawValue)
        super.init()
        Task { [weak self] in
            await self?.relockIfNeeded()
            await self?.announceTop()
        }
        scheduleRelock()
    }

    private let relockLock = NSLock()
    private var relockTask: Task<Void, Never>?

    /// 열림 시간이 끝나는 때에 맞춰 잠금 폴더를 다시 잠근다. 파일 앱을 나가 있는 동안 시간이 다 돼도
    /// 돌아왔을 때 예전 목록 대신 "인증 필요" 가 뜨도록. (확장이 그 전에 끝나면 다음에 뜰 때 바로 잠근다)
    private func scheduleRelock() {
        relockLock.lock(); defer { relockLock.unlock() }
        guard relockTask == nil, let server, !server.locked.isEmpty, LockState.isUnlocked(server.id) else { return }
        let id = server.id
        relockTask = Task { [weak self] in
            while !Task.isCancelled {
                let wait = LockState.unlockedUntil(id) - Date().timeIntervalSince1970
                if wait <= 0 { break }
                try? await Task.sleep(for: .seconds(wait + 1))
            }
            guard let self, !Task.isCancelled else { return }
            self.relockLock.withLock { self.relockTask = nil }
            await self.relockIfNeeded()
        }
    }

    private var marks: LockMarks { Self.marks(serverID: domain.identifier.rawValue) }

    static func marks(serverID: String) -> LockMarks {
        guard let server = ServerStore.server(id: serverID) else { return .none }
        return LockMarks(locked: server.locked, epoch: LockState.epoch(server.id))
    }

    /// 잠금 폴더를 지금 번호의 식별자로 하나씩 만든다
    private func lockedFolderItems(_ marks: LockMarks) -> [NASItem] {
        marks.locked.map { locked in
            let id = marks.mark(locked)
            return NASItem(id: NSFileProviderItemIdentifier(id), parent: ItemPath.parent(of: id),
                           name: (locked as NSString).lastPathComponent, isFolder: true, size: nil, modified: nil,
                           isShare: !locked.contains("/"))
        }
    }

    /// 확장이 뜰 때마다 고른 공유와 잠금 폴더를 working set 으로 한 번 다시 알린다 (이미 있으면 그대로).
    /// 예전 빌드가 남긴 표시 없는 잠금 폴더("Book")는 지운다.
    private func announceTop() async {
        guard let server, !server.shares.isEmpty else { return }
        let marks = marks
        var items = server.shares.filter { !server.locked.contains($0) }
            .map { NASItem.folder(id: $0, parent: .rootContainer, name: $0) }
        items += lockedFolderItems(marks)
        await snapshots.apply(deletes: server.locked, updates: items, clearing: [])
        try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
    }

    /// 잠금 시간이 지났으면(한 번 잠근 뒤 다시 열리기 전까지 한 번만) 번호를 올려 잠금 폴더를 새 식별자로 바꾼다.
    /// 예전 식별자 폴더를 지우면 파일 앱이 기억해 둔 안쪽 목록·받은 파일도 같이 빠지고,
    /// 새 식별자 폴더는 처음 보는 폴더라 열 때 목록을 새로 물어 그때 "인증 필요" 가 뜬다.
    /// (같은 식별자로 지웠다 넣거나 evict 하는 방법은 파일 앱이 예전 목록을 붙여 두거나 "사용 중" 으로 거절해 안 됐다)
    func relockIfNeeded() async {
        guard let server, !server.locked.isEmpty, !LockState.isUnlocked(server.id) else { return }
        guard await snapshots.beginRelock() else { return }
        let old = LockState.epoch(server.id)
        let new = LockState.bumpEpoch(server.id)
        let oldMarks = LockMarks(locked: server.locked, epoch: old)
        let deletes = server.locked.flatMap { [$0, oldMarks.mark($0)] }
        await snapshots.apply(deletes: deletes, updates: lockedFolderItems(LockMarks(locked: server.locked, epoch: new)),
                              clearing: server.locked)
        log.notice("잠금 폴더 다시 잠금 \(server.locked, privacy: .public) 번호 \(old)→\(new)")
        try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
    }

    func invalidate() {
        relockLock.withLock { relockTask?.cancel() }
    }

    private var server: NASServer? { ServerStore.server(id: domain.identifier.rawValue) }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if identifier == .rootContainer {
            completionHandler(NASItem.root(name: domain.displayName), nil)
            return Progress()
        }
        if marks.isStale(identifier.rawValue) {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        let (share, path) = ItemPath.split(identifier.rawValue)
        if path == "/" {
            completionHandler(NASItem.folder(id: identifier.rawValue, parent: .rootContainer, name: share), nil)
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
        let newID = ItemPath.child(of: parent.rawValue, name: ItemPath.nfc(itemTemplate.filename), marks: marks)
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
        // 파일 앱이 폴더를 열 때 고치는 마지막 사용 시각·태그 같은 정보는 NAS 에 둘 곳이 없으니 그냥 받는다.
        // 잠금으로 거절하면 "올리기 대기" 로 남아 폴더가 계속 사용 중이 되고 비우기(evict)도 막힌다.
        if changedFields.isDisjoint(with: [.filename, .parentItemIdentifier, .contents]) {
            log.debug("정보만 바뀜 \(oldID, privacy: .public) \(changedFields.rawValue)")
            completionHandler(item, [], false, nil)
            return progress
        }
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
                    let newID = ItemPath.child(of: item.parentItemIdentifier.rawValue, name: ItemPath.nfc(item.filename), marks: marks)
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
        if marks.isStale(containerItemIdentifier.rawValue) {
            throw NSFileProviderError(.noSuchItem)
        }
        if containerItemIdentifier != .rootContainer, containerItemIdentifier != .workingSet,
           let error = lockError(for: containerItemIdentifier.rawValue) {
            throw error
        }
        let serverID = domain.identifier.rawValue
        return NASEnumerator(container: containerItemIdentifier, shares: server?.shares ?? [], smb: smb,
                             snapshots: snapshots, manager: NSFileProviderManager(for: domain),
                             marks: { Self.marks(serverID: serverID) },
                             isLockedNow: { id in
                                 guard let server = ServerStore.server(id: serverID) else { return false }
                                 return server.isLocked(ItemPath.clean(id)) && !LockState.isUnlocked(server.id)
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
    private func lockError(for id: String, caller: String = #function) -> Error? {
        let path = ItemPath.clean(id)
        guard let server, server.isLocked(path) else { return nil }
        log.debug("잠금 확인 \(caller, privacy: .public) \(path, privacy: .public) 열림=\(LockState.isUnlocked(server.id))")
        if LockState.isUnlocked(server.id) {
            LockState.touch(server.id)
            scheduleRelock()
            // 열렸으니 다음에 시간이 다 되면 다시 잠글 수 있게
            Task { [snapshots] in await snapshots.unlocked() }
            return nil
        }
        LockState.requestAuth(server.id)
        hideLockedContents()
        return NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.notAuthenticated.rawValue,
                       userInfo: [AuthReason.key: AuthReason.lockedFolder])
    }

    func hideLockedContents() {
        Task { await relockIfNeeded() }
    }
}

final class NASEnumerator: NSObject, NSFileProviderEnumerator {
    let container: NSFileProviderItemIdentifier
    let shares: [String]
    let smb: SMBConnections
    let snapshots: FolderSnapshots
    /// 파일 앱이 열거자를 오래 붙들고 있으니 잠금 번호는 쓸 때마다 새로 읽는다
    let marks: @Sendable () -> LockMarks

    private var watcher: Task<Void, Never>?

    init(container: NSFileProviderItemIdentifier, shares: [String], smb: SMBConnections, snapshots: FolderSnapshots,
         manager: NSFileProviderManager?, marks: @escaping @Sendable () -> LockMarks,
         isLockedNow: @escaping @Sendable (String) -> Bool, relock: @escaping @Sendable () -> Void) {
        self.container = container
        self.shares = shares
        self.smb = smb
        self.snapshots = snapshots
        self.marks = marks
        super.init()
        if container != .rootContainer, container != .workingSet {
            watcher = Self.watch(container.rawValue, smb: smb, snapshots: snapshots, manager: manager, marks: marks,
                                 isLockedNow: isLockedNow, relock: relock)
        }
    }

    /// 파일 앱이 폴더를 보고 있는 동안(invalidate 전까지) 10초마다 NAS 를 다시 읽어,
    /// 달라졌으면 working set 으로 알린다 → 맥·다른 기기에서 바꾼 것이 곧 보인다
    private static func watch(_ id: String, smb: SMBConnections, snapshots: FolderSnapshots,
                              manager: NSFileProviderManager?, marks: @escaping @Sendable () -> LockMarks,
                              isLockedNow: @escaping @Sendable (String) -> Bool,
                              relock: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                // 보고 있던 잠금 폴더의 시간이 다 되면 목록을 감추고 지켜보기를 멈춘다
                if isLockedNow(id) {
                    relock()
                    return
                }
                if await snapshots.refresh(id, smb: smb, marks: marks()) {
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
            let marks = marks()
            observer.didEnumerate(shares.map { NASItem.folder(id: marks.mark($0), parent: .rootContainer, name: $0) })
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
                let marks = marks()
                let items = entries.compactMap { entry -> NASItem? in
                    guard let name = entry[.nameKey] as? String, !ItemPath.isHidden(name) else { return nil }
                    return NASItem(path: ItemPath.child(of: id, name: name, marks: marks), attributes: entry)
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
            // 예전 번호 잠금 폴더를 먼저 지우고 새 번호 폴더를 넣는다 (같은 이름이 잠깐 둘이 되지 않도록)
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
    /// 시간이 다 돼 이미 다시 잠갔는지 (확장이 다시 떠도 같은 잠금에 또 번호를 올리지 않도록 파일에 둔다)
    private var relocked: Bool {
        didSet { try? Data((relocked ? "1" : "0").utf8).write(to: relockedFile, options: .atomic) }
    }
    private let relockedFile: URL
    private(set) var generation = 0
    private let file: URL

    init(domainID: String) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        file = caches.appendingPathComponent("listings-\(domainID).json")
        listings = (try? JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: file))) ?? [:]
        relockedFile = caches.appendingPathComponent("relocked-\(domainID)")
        relocked = (try? Data(contentsOf: relockedFile)) == Data("1".utf8)
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
    func refresh(_ id: String, smb: SMBConnections, marks: LockMarks) async -> Bool {
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
            let childID = ItemPath.child(of: id, name: name, marks: marks)
            pendingUpdates[childID] = NASItem(path: childID, attributes: entry)
            pendingDeletes.remove(childID)
            found = true
        }
        for name in before.keys where now[name] == nil {
            let childID = ItemPath.child(of: id, name: name, marks: marks)
            pendingDeletes.insert(childID)
            pendingUpdates[childID] = nil
            found = true
        }
        if found { generation += 1 }
        return found
    }

    /// 아직 다시 잠그지 않았으면 표시하고 true
    func beginRelock() -> Bool {
        guard !relocked else { return false }
        relocked = true
        return true
    }

    func unlocked() {
        if relocked { relocked = false }
    }

    /// working set 으로 넘길 지우기·넣기를 모은다. clearing 경로 아래 기억해 둔 목록은 버린다.
    func apply(deletes: [String], updates: [NASItem], clearing: [String]) {
        for id in deletes {
            pendingDeletes.insert(id)
            pendingUpdates[id] = nil
        }
        for item in updates {
            pendingUpdates[item.itemIdentifier.rawValue] = item
            pendingDeletes.remove(item.itemIdentifier.rawValue)
        }
        for locked in clearing {
            for key in listings.keys {
                let path = ItemPath.clean(key)
                guard path == locked || path.hasPrefix(locked + "/") else { continue }
                listings[key] = nil
                checkedAt[key] = nil
            }
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

/// 잠금 폴더 식별자에 붙이는 다시 잠근 번호. "|" 는 SMB 이름에 쓸 수 없는 글자라 실제 이름과 겹치지 않는다.
struct LockMarks: Sendable {
    let locked: [String]
    let epoch: Int
    static let none = LockMarks(locked: [], epoch: 0)

    /// 식별자가 가리키는 경로가 잠금 폴더 자체면 끝에 번호를 붙인다
    func mark(_ id: String) -> String {
        locked.contains(ItemPath.clean(id)) ? ItemPath.dropMark(id) + "|\(epoch)" : id
    }

    /// 예전 번호(또는 번호 없는) 잠금 폴더이거나 그 안의 식별자인지
    func isStale(_ id: String) -> Bool {
        guard !locked.isEmpty else { return false }
        var path = ""
        for part in id.split(separator: "/", omittingEmptySubsequences: true) {
            let name = ItemPath.dropMark(String(part))
            path = path.isEmpty ? name : path + "/" + name
            if locked.contains(path), part != "\(name)|\(epoch)" { return true }
        }
        return false
    }
}

enum ItemPath {
    /// "Book|3" → "Book"
    static func dropMark(_ part: String) -> String {
        guard let bar = part.lastIndex(of: "|"), !part[part.index(after: bar)...].isEmpty,
              part[part.index(after: bar)...].allSatisfy(\.isNumber) else { return part }
        return String(part[..<bar])
    }

    /// 식별자에서 잠금 번호를 떼어 낸 실제 경로: "Book|3/a.pdf" → "Book/a.pdf"
    static func clean(_ id: String) -> String {
        guard id.contains("|") else { return id }
        return id.split(separator: "/", omittingEmptySubsequences: false).map { dropMark(String($0)) }.joined(separator: "/")
    }

    /// "공유/a/b" → ("공유", "/a/b"), "공유" → ("공유", "/")
    static func split(_ id: String) -> (share: String, path: String) {
        let parts = clean(id).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
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

    static func child(of parent: String, name: String, marks: LockMarks) -> String {
        marks.mark(parent + "/" + name)
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
                  name: ItemPath.dropMark((path as NSString).lastPathComponent), isFolder: isFolder,
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
