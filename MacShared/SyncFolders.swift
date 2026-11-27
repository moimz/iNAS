import AppKit
import CloudKit
import Foundation

/// 동기화할 폴더. iCloud 에는 고유값(레코드 이름) · 폴더명 · 예외 목록이 올라가고 모든 Mac 에서 같게 보인다.
struct SyncFolder: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var name: String
    /// 동기화 예외 목록 (한 줄에 하나, Syncthing .stignore 문법). 모든 Mac 공통
    var ignores: String = SyncFolder.defaultIgnores

    /// 새 폴더의 예외 목록 기본값: 맥이 저절로 만드는 파일
    static let defaultIgnores = """
    // 맥이 저절로 만드는 파일
    (?d).DS_Store
    (?d)._*
    (?d).Spotlight-V100
    (?d).Trashes
    (?d).fseventsd
    (?d).TemporaryItems
    """

    init(id: String, name: String, ignores: String = SyncFolder.defaultIgnores) {
        self.id = id
        self.name = name
        self.ignores = ignores
    }

    // 예외 목록이 없던 옛 캐시도 읽히게
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        ignores = try c.decodeIfPresent(String.self, forKey: .ignores) ?? ""
    }
}

/// 이 Mac 에서만 쓰는 폴더 설정 (iCloud 에 안 올림)
struct LocalFolderSetting: Codable, Equatable {
    var enabled = false
    var path: String?
    var bookmark: Data?
}

/// 폴더 목록(iCloud CloudKit, Sync 영역 SyncFolder 기록)과 이 Mac 의 폴더 설정(UserDefaults)
@MainActor
final class SyncFolderStore: ObservableObject {
    nonisolated static let recordType = "SyncFolder"
    private static let cacheKey = "syncFolders"
    private static let localKey = "syncFolderLocal"

    @Published private(set) var folders: [SyncFolder] = []
    @Published private(set) var local: [String: LocalFolderSetting] = [:]
    /// iCloud 오류 (없으면 nil). 못 올린 것이 남아 있으면 지우지 않는다
    @Published private(set) var iCloudError: String?
    /// 아직 iCloud 에 못 올린 폴더 아이디 (다시 올림, 껐다 켜도 기억)
    @Published private(set) var unsynced: Set<String> = []
    private static let unsyncedKey = "syncFoldersUnsynced"

    private lazy var database = CKContainer(identifier: SyncDiscovery.containerID).privateCloudDatabase
    private var zoneReady = false
    private var changeToken: CKServerChangeToken?
    private var timer: Timer?
    private var polling = false
    /// 고치는 중 iCloud 에서 받은 옛 값으로 되돌아가지 않게 (아이디 → 올릴 폴더)
    private var pendingEdits: [String: SyncFolder] = [:]
    private var editTasks: [String: Task<Void, Never>] = [:]

    /// 에이전트는 읽기만 한다 (폴더 고침 · iCloud 올리기는 앱 창만)
    let readOnly: Bool

    init(readOnly: Bool = false) {
        self.readOnly = readOnly
        let d = Prefs.defaults
        if let data = d.data(forKey: Self.cacheKey), let f = try? JSONDecoder().decode([SyncFolder].self, from: data) { folders = f }
        if let data = d.data(forKey: Self.localKey), let l = try? JSONDecoder().decode([String: LocalFolderSetting].self, from: data) { local = l }
        unsynced = Set(d.stringArray(forKey: Self.unsyncedKey) ?? [])
        guard !readOnly else { unsynced = []; return }
        // 빌드 64 는 못 올린 폴더를 기억하지 않았다: 처음 한 번은 있는 폴더를 모두 다시 올린다(덮어쓰기라 해가 없음)
        if !d.bool(forKey: "syncFoldersReuploadOnce") {
            d.set(true, forKey: "syncFoldersReuploadOnce")
            unsynced.formUnion(folders.map(\.id))
            d.set(Array(unsynced), forKey: Self.unsyncedKey)
        }
    }

    func start() {
        guard timer == nil else { return }
        Task { await poll() }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.poll() } }
        }
    }

    func folder(_ id: String) -> SyncFolder? { folders.first { $0.id == id } }

    /// 앱 창이 이 Mac 설정(동기화 토글 · 로컬 폴더)을 바꿨을 때 에이전트가 다시 읽는다
    func reloadLocal() {
        if let data = Prefs.defaults.data(forKey: Self.localKey),
           let l = try? JSONDecoder().decode([String: LocalFolderSetting].self, from: data), l != local {
            local = l
        }
    }

    /// 이 Mac 에서 켜고 로컬 폴더를 고른 폴더 → 엔진 설정
    func engineConfigs() -> [SyncFolderConfig] {
        folders.compactMap { f in
            let s = setting(f.id)
            guard s.enabled, let path = resolvedPath(f.id) else { return nil }
            return SyncFolderConfig(id: f.id, name: f.name, path: path, ignores: f.ignores)
        }
    }

    /// 이 Mac 에서 켠 폴더가 있는지 (에이전트를 늘 띄워야 하는지)
    var anyEnabled: Bool { local.values.contains { $0.enabled && $0.path != nil } }
    func setting(_ id: String) -> LocalFolderSetting { local[id] ?? LocalFolderSetting() }

    // MARK: 고치기

    /// 새 폴더: 고유값은 UUID, 이름은 "새 폴더"(겹치면 번호)
    @discardableResult
    func add() -> SyncFolder {
        var name = "새 폴더"
        var n = 2
        while folders.contains(where: { $0.name == name }) {
            name = "새 폴더 \(n)"
            n += 1
        }
        let folder = SyncFolder(id: UUID().uuidString, name: name)
        folders.append(folder)
        sortAndCache()
        Task { await upload(folder) }
        return folder
    }

    /// 폴더명 바꾸기
    func rename(_ id: String, to name: String) {
        edit(id) { $0.name = name }
    }

    /// 예외 목록 바꾸기
    func setIgnores(_ id: String, _ text: String) {
        edit(id) { $0.ignores = text }
    }

    /// 화면에는 바로, iCloud 에는 입력이 1초 멈추면 올린다 (두 Mac 에서 동시에 고치면 나중에 올린 쪽이 남는다)
    private func edit(_ id: String, _ change: (inout SyncFolder) -> Void) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        var f = folders[i]
        change(&f)
        guard f != folders[i] else { return }
        folders[i] = f
        cache()
        pendingEdits[id] = f
        editTasks[id]?.cancel()
        editTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let f = self.folder(id) else { return }
            await self.upload(f)
            if self.pendingEdits[id] == f { self.pendingEdits[id] = nil }
            self.sortAndCache()
        }
    }

    /// 모든 Mac 에서 지운다 (각 Mac 의 로컬 폴더 내용은 건드리지 않는다)
    func delete(_ id: String) {
        folders.removeAll { $0.id == id }
        local[id] = nil
        pendingEdits[id] = nil
        setUnsynced(id, false)
        saveLocal()
        cache()
        Task {
            do {
                _ = try await database.modifyRecords(saving: [], deleting: [CKRecord.ID(recordName: id, zoneID: SyncDiscovery.zoneID)])
            } catch {
                iCloudError = "삭제를 iCloud 에 못 올림: \(error.localizedDescription)"
                Log.app.error("folders: \(self.iCloudError ?? "", privacy: .public)")
            }
        }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        var s = setting(id)
        s.enabled = on
        local[id] = s
        saveLocal()
    }

    /// 로컬 폴더 고르기 (NSOpenPanel). 비어 있지 않으면 경고하고 다시 고를 수 있게 한다.
    func chooseLocalFolder(_ id: String) {
        var start = setting(id).path.map { URL(fileURLWithPath: $0) }
        while true {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.prompt = "선택"
            panel.message = "\(folder(id)?.name ?? "폴더") 와 동기화할 이 Mac 의 폴더를 고르세요."
            if let start { panel.directoryURL = start }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            switch confirmNonEmpty(url) {
            case .use:
                var s = setting(id)
                s.path = url.path
                s.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                local[id] = s
                saveLocal()
                return
            case .chooseAgain:
                start = url.deletingLastPathComponent()
            case .cancel:
                return
            }
        }
    }

    private enum NonEmptyChoice { case use, chooseAgain, cancel }

    /// 안에 파일이 있으면(맥이 만드는 .DS_Store 같은 것은 빼고) 경고
    private func confirmNonEmpty(_ url: URL) -> NonEmptyChoice {
        let (files, more) = Self.countItems(url, limit: 10_000)
        guard files > 0 else { return .use }
        let count = more ? "10,000개가 넘는" : "\(files.formatted())개의"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "「\(url.lastPathComponent)」 폴더가 비어 있지 않습니다"
        alert.informativeText = """
        안에 있는 \(count) 항목이 다른 Mac 의 같은 폴더와 합쳐집니다. \
        같은 이름인데 내용이 다른 파일은 충돌 사본(.sync-conflict)으로 남고, \
        파일이 많으면 처음 동기화에 시간이 걸릴 수 있습니다.
        """
        alert.addButton(withTitle: "이 폴더 사용")
        alert.addButton(withTitle: "다른 폴더 고르기")
        alert.addButton(withTitle: "취소")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .use
        case .alertSecondButtonReturn: return .chooseAgain
        default: return .cancel
        }
    }

    /// 폴더 안 항목 수 (하위 폴더 포함, limit 까지만 센다)
    nonisolated static func countItems(_ url: URL, limit: Int) -> (Int, Bool) {
        let skip: Set<String> = [".DS_Store", ".localized", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems"]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return (0, false) }
        var n = 0
        for case let item as URL in e {
            if skip.contains(item.lastPathComponent) || item.lastPathComponent.hasPrefix("._") {
                e.skipDescendants()
                continue
            }
            n += 1
            if n >= limit { return (n, true) }
        }
        return (n, false)
    }

    /// 고른 폴더가 옮겨졌거나 이름이 바뀌었으면 북마크로 지금 경로를 찾는다
    func resolvedPath(_ id: String) -> String? {
        let s = setting(id)
        if let data = s.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url.path
            }
        }
        return s.path
    }

    // MARK: iCloud

    func poll() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        do {
            if !zoneReady {
                _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: SyncDiscovery.zoneID)], deleting: [])
                zoneReady = true
            }
            var changed = false
            while true {
                let r = try await database.recordZoneChanges(inZoneWith: SyncDiscovery.zoneID, since: changeToken)
                for (_, result) in r.modificationResultsByID {
                    guard case .success(let m) = result, m.record.recordType == Self.recordType else { continue }
                    let id = m.record.recordID.recordName
                    let f = pendingEdits[id] ?? SyncFolder(
                        id: id, name: m.record["name"] as? String ?? "", ignores: m.record["ignores"] as? String ?? SyncFolder.defaultIgnores
                    )
                    if let i = folders.firstIndex(where: { $0.id == id }) {
                        if folders[i] != f { folders[i] = f; changed = true }
                    } else {
                        folders.append(f)
                        changed = true
                    }
                }
                for d in r.deletions where d.recordType == Self.recordType {
                    let id = d.recordID.recordName
                    if folders.contains(where: { $0.id == id }) {
                        folders.removeAll { $0.id == id }
                        changed = true
                    }
                }
                changeToken = r.changeToken
                if !r.moreComing { break }
            }
            if changed { sortAndCache() }
            // 못 올린 것 다시 올리기 (그사이 지워진 것은 뺀다)
            for id in unsynced where !readOnly {
                if let f = folder(id) { await upload(f) } else { setUnsynced(id, false) }
            }
            if unsynced.isEmpty { iCloudError = nil }
        } catch {
            iCloudError = "iCloud 오류: \(error.localizedDescription)"
            Log.app.error("folders: \(self.iCloudError ?? "", privacy: .public)")
            if let ck = error as? CKError, ck.code == .changeTokenExpired { changeToken = nil }
        }
    }

    private func upload(_ f: SyncFolder) async {
        do {
            try await Self.save(f, in: database)
            setUnsynced(f.id, false)
            if unsynced.isEmpty { iCloudError = nil }
        } catch {
            setUnsynced(f.id, true)
            iCloudError = "iCloud 에 못 올림(15초마다 다시): \(error.localizedDescription)"
            Log.app.error("folders: \(self.iCloudError ?? "", privacy: .public)")
        }
    }

    private func setUnsynced(_ id: String, _ on: Bool) {
        let before = unsynced
        if on { unsynced.insert(id) } else { unsynced.remove(id) }
        if unsynced != before { Prefs.defaults.set(Array(unsynced), forKey: Self.unsyncedKey) }
    }

    nonisolated static func record(from f: SyncFolder) -> CKRecord {
        let rec = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: f.id, zoneID: SyncDiscovery.zoneID))
        rec["name"] = f.name
        rec["ignores"] = f.ignores
        return rec
    }

    nonisolated static func save(_ f: SyncFolder, in db: CKDatabase) async throws {
        let r = try await db.modifyRecords(saving: [record(from: f)], deleting: [], savePolicy: .allKeys, atomically: false)
        for (_, result) in r.saveResults {
            if case .failure(let e) = result { throw e }
        }
    }

    // MARK: 저장

    private func sortAndCache() {
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cache()
    }

    private func cache() {
        if let data = try? JSONEncoder().encode(folders) { Prefs.defaults.set(data, forKey: Self.cacheKey) }
    }

    private func saveLocal() {
        if let data = try? JSONEncoder().encode(local) { Prefs.defaults.set(data, forKey: Self.localKey) }
    }
}
