import AppKit
import CloudKit
import Foundation

/// 동기화할 폴더. iCloud 에는 고유값(레코드 이름)과 폴더명만 올라가고 모든 Mac 에서 같게 보인다.
struct SyncFolder: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var name: String
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
    /// iCloud 오류 (없으면 nil)
    @Published private(set) var iCloudError: String?

    private lazy var database = CKContainer(identifier: SyncDiscovery.containerID).privateCloudDatabase
    private var zoneReady = false
    private var changeToken: CKServerChangeToken?
    private var timer: Timer?
    private var polling = false
    /// 이름을 고치는 중 iCloud 에서 받은 옛 이름으로 되돌아가지 않게 (아이디 → 올릴 이름)
    private var pendingNames: [String: String] = [:]
    private var nameTasks: [String: Task<Void, Never>] = [:]

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.cacheKey), let f = try? JSONDecoder().decode([SyncFolder].self, from: data) { folders = f }
        if let data = d.data(forKey: Self.localKey), let l = try? JSONDecoder().decode([String: LocalFolderSetting].self, from: data) { local = l }
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

    /// 폴더명 바꾸기: 화면에는 바로, iCloud 에는 입력이 1초 멈추면 올린다
    func rename(_ id: String, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }), folders[i].name != name else { return }
        folders[i].name = name
        cache()
        pendingNames[id] = name
        nameTasks[id]?.cancel()
        nameTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let f = self.folder(id) else { return }
            await self.upload(f)
            if self.pendingNames[id] == f.name { self.pendingNames[id] = nil }
            self.sortAndCache()
        }
    }

    /// 모든 Mac 에서 지운다 (각 Mac 의 로컬 폴더 내용은 건드리지 않는다)
    func delete(_ id: String) {
        folders.removeAll { $0.id == id }
        local[id] = nil
        pendingNames[id] = nil
        saveLocal()
        cache()
        Task {
            do {
                _ = try await database.modifyRecords(saving: [], deleting: [CKRecord.ID(recordName: id, zoneID: SyncDiscovery.zoneID)])
            } catch {
                iCloudError = "삭제를 iCloud 에 못 올림: \(error.localizedDescription)"
            }
        }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        var s = setting(id)
        s.enabled = on
        local[id] = s
        saveLocal()
    }

    /// 로컬 폴더 고르기 (NSOpenPanel)
    func chooseLocalFolder(_ id: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "선택"
        panel.message = "\(folder(id)?.name ?? "폴더") 와 동기화할 이 Mac 의 폴더를 고르세요."
        if let path = setting(id).path { panel.directoryURL = URL(fileURLWithPath: path) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var s = setting(id)
        s.path = url.path
        s.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        local[id] = s
        saveLocal()
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
                    let name = pendingNames[id] ?? (m.record["name"] as? String ?? "")
                    if let i = folders.firstIndex(where: { $0.id == id }) {
                        if folders[i].name != name { folders[i].name = name; changed = true }
                    } else {
                        folders.append(SyncFolder(id: id, name: name))
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
            iCloudError = nil
        } catch {
            iCloudError = "iCloud 오류: \(error.localizedDescription)"
            if let ck = error as? CKError, ck.code == .changeTokenExpired { changeToken = nil }
        }
    }

    private func upload(_ f: SyncFolder) async {
        do {
            try await Self.save(f, in: database)
            iCloudError = nil
        } catch {
            iCloudError = "iCloud 에 못 올림: \(error.localizedDescription)"
        }
    }

    nonisolated static func record(from f: SyncFolder) -> CKRecord {
        let rec = CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: f.id, zoneID: SyncDiscovery.zoneID))
        rec["name"] = f.name
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
        if let data = try? JSONEncoder().encode(folders) { UserDefaults.standard.set(data, forKey: Self.cacheKey) }
    }

    private func saveLocal() {
        if let data = try? JSONEncoder().encode(local) { UserDefaults.standard.set(data, forKey: Self.localKey) }
    }
}
