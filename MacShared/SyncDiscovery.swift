import AppKit
import CloudKit
import Foundation
import Network

/// 같은 iCloud 계정의 기기에 기록한 "나는 누구, 어디서 기다림"
struct SyncDevice: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var model: String
    var modelID: String
    var os: String
    var appVersion: String
    var localIP: String
    var publicIP: String
    /// 바깥에서 붙을 포트 (공유기에 연 포트, 공인 IP 바로면 대기 포트)
    var port: Int
    /// 이 기기 안에서 기다리는 포트
    var internalPort: Int
    /// "UPnP (ipTIME A3008-MU)", "공인 IP 바로", "열지 못함: …"
    var portMethod: String
    /// 바깥에서 붙을 수 있다고 보는지 (포트를 열었거나 공인 IP 바로)
    var reachable: Bool
    var updatedAt: Date
    /// 이 기기가 본 다른 기기(아이디)와의 연결. CloudKit 칸 이름은 reach (운영 스키마를 다시 안 올리려고 그대로 씀)
    var links: [String: SyncLinkInfo]
    /// 동기화 공개 키(Curve25519, base64). 같은 iCloud 계정의 이 키를 가진 기기만 암호화 연결을 맺을 수 있다
    var publicKey: String = ""
    /// 이 기기가 동기화하는 폴더(고유값 → 상태). 각 기기가 자기 기록에만 쓰므로 충돌이 없다 (아이폰은 이걸 보고 붙을 Mac 을 고른다)
    var folders: [String: SyncDeviceFolder] = [:]
}

/// 기기 기록에 올리는 폴더 상태 (로컬 경로는 안 올린다)
struct SyncDeviceFolder: Codable, Equatable {
    var state: String
    var needItems: Int
    var lastSync: Date?
}

/// 지운(차단한) 기기: 이 키는 다시 올라와도 믿지 않는다 (기록 이름 = 키 아이디)
struct SyncBlockedDevice: Codable, Equatable, Identifiable {
    var keyID: String
    var name: String
    var revokedAt: Date
    var id: String { keyID }
}

/// 한 기기와의 연결 상태
struct SyncLinkInfo: Codable, Equatable {
    var up: Bool
    /// 내가 붙었는지(아니면 저쪽이 붙어 옴)
    var outgoing: Bool
    /// "외부 1.2.3.4:47731", "내부 192.168.0.5:47731", 받은 쪽은 상대 주소
    var via: String
    var since: Date?
    var lastSeen: Date?
    var rtt: Int?
    var error: String?
    var at: Date
}

/// 두 기기 사이에 누가 붙을지
enum SyncRole: Equatable {
    case dial(host: String, port: Int, via: String, reason: String)
    case wait(reason: String)
    case none(reason: String)

    var text: String {
        switch self {
        case .dial(_, _, let via, let reason): return "내가 붙음 → \(via) (\(reason))"
        case .wait(let reason): return "저쪽이 붙어 오길 기다림 (\(reason))"
        case .none(let reason): return "연결 안 함 (\(reason))"
        }
    }
}

/// 설정 > 동기화 (시험): 기기 정보 · 공인 IP · 포트 열기 · 대기 · iCloud 등록 · 역할을 정해 한쪽이 붙고 연결 유지.
/// 네트워크 확인 1분, iCloud 목록 15초, 연결 관리 5초마다 (앱이 떠 있는 동안).
@MainActor
final class SyncDiscovery: ObservableObject {
    nonisolated static let containerID = "iCloud.com.moimz.iNAS"
    nonisolated static let recordType = "SyncDevice"
    static let basePort: UInt16 = 47731
    nonisolated static let zoneID = CKRecordZone.ID(zoneName: "Sync", ownerName: CKCurrentUserDefaultName)
    /// 이만큼 소식이 없으면 꺼진 기기로 본다 (iCloud 기록은 1분마다 올림)
    static let staleAfter: TimeInterval = 3 * 60

    @Published private(set) var me: SyncDevice
    @Published private(set) var peers: [SyncDevice] = []
    @Published private(set) var listenStatus = "시작 전"
    @Published private(set) var stunStatus = ""
    @Published private(set) var iCloudStatus = "확인 전"
    @Published private(set) var iCloudOK = false
    @Published private(set) var busy = false
    @Published private(set) var log: [(Date, String)] = []
    /// 폴더 아이디 → 동기화 상태 (엔진)
    @Published private(set) var folderStatus: [String: SyncFolderStatus] = [:]

    /// 이 Mac 의 키 (비밀 키는 키체인)
    let identity: SyncIdentity
    let engine: SyncEngine
    private var listener: NWListener?
    private var listenerPort: UInt16 = 0
    private var listenerKeys: [String] = []
    /// 엔진에 살아 있는 연결 (키 아이디 → 연결)
    private var engineLinks: [String: SyncPeerLink] = [:]
    /// 내가 붙은(붙는 중인) 키 아이디
    private var outgoingKeys: Set<String> = []
    private var dialingIDs: Set<String> = []
    private var watchers: [String: SyncWatcher] = [:]
    /// 차단한 키 (키 아이디 → 기록)
    @Published private(set) var blocked: [String: SyncBlockedDevice] = [:]
    nonisolated static let blockRecordType = "SyncBlock"
    private var cleanedOldRecord = false
    private var folderConfigs: [SyncFolderConfig] = []
    private var gateway: UPnPGateway?
    private var mappedExternal: UInt16?
    private var timers: [Timer] = []
    private var zoneReady = false
    private var changeToken: CKServerChangeToken?
    private var iCloudBusy = false
    private var iCloudAgain = false
    private var iCloudAgainForce = false
    private var allDevices: [String: SyncDevice] = [:]
    private var lastSaved: SyncDevice?
    private var lastSavedAt = Date.distantPast
    private lazy var database = CKContainer(identifier: Self.containerID).privateCloudDatabase

    /// 다시 붙기 전 기다림
    private var nextDial: [String: Date] = [:]
    private var dialFailures: [String: Int] = [:]
    /// 역할이 wait 가 된 시각 (오래 안 붙어 오면 나도 붙어 본다)
    private var waitingSince: [String: Date] = [:]
    private var lastDump = Date.distantPast

    init() {
        // 기기 아이디: 이 Mac 의 하드웨어 고유값 + 사용자 계정으로 정한다 → 포맷 · 다시 설치해도 같은 기록을 덮어쓴다(중복 없음)
        let id = DeviceInfo.stableDeviceID
        me = SyncDevice(
            id: id, name: DeviceInfo.computerName, model: DeviceInfo.productName ?? DeviceInfo.modelIdentifier,
            modelID: DeviceInfo.modelIdentifier, os: DeviceInfo.osVersion, appVersion: AppVersion.text,
            localIP: "", publicIP: "", port: 0, internalPort: 0, portMethod: "", reachable: false,
            updatedAt: .distantPast, links: [:]
        )
        let identity = SyncKeyStore.loadOrCreate()
        self.identity = identity
        let stateDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.moimz.iNAS/sync", isDirectory: true)
        var noteBox: (@Sendable (String) -> Void)?
        engine = SyncEngine(identity: identity, name: DeviceInfo.computerName, stateDir: stateDir, log: { line in noteBox?(line) })
        noteBox = { [weak self] line in Task { @MainActor in self?.note(line) } }
        me.publicKey = identity.publicKey.rawRepresentation.base64EncodedString()
    }

    func start() {
        guard timers.isEmpty else { return }
        Task {
            await engine.setStatusHandler { [weak self] st in Task { @MainActor in self?.engineStatus(st) } }
            await engine.setLinkHandler { [weak self] links in Task { @MainActor in self?.linksChanged(links) } }
            await refresh()
        }
        timers = [
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            },
            Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.pollICloud() }
            },
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.manageLinks() }
            },
            // FSEvents 를 놓친 것까지: 한 시간마다 전체를 다시 훑는다 (Syncthing 기본과 같음)
            Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.engine.rescanAll() }
            },
        ]
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePortSync() }
        }
    }

    /// 네트워크 한 바퀴: 내 정보 → 대기 → 공인 IP → 포트 열기 → iCloud 올리고 받기
    func refresh() async {
        guard !busy else { return }
        busy = true
        defer {
            busy = false
            dumpForDebug()
        }
        me.name = DeviceInfo.computerName
        me.localIP = DeviceInfo.primaryIPv4() ?? ""

        await ensureListening()

        do {
            let r = try await STUN.publicAddress()
            if r.ip != me.publicIP {
                note("공인 IP \(r.ip) (STUN \(r.server))")
                if !me.publicIP.isEmpty {
                    note("공인 IP 가 바뀌어 붙어 본 기록을 지움")
                    networkChanged()
                }
            }
            me.publicIP = r.ip
            stunStatus = "STUN \(r.server)"
        } catch {
            stunStatus = "공인 IP 를 못 알아냄: \(error.localizedDescription)"
            note(stunStatus)
        }

        await openPort()
        await pollICloud(forceSave: true)
        manageLinks()
    }

    // MARK: 대기

    /// 같은 iCloud 기기들의 키로 TLS(ECDHE-PSK) 대기. 기기 키 목록이 바뀌면 같은 포트에서 다시 연다
    private func ensureListening() async {
        let keys = syncPeers().map(\.keyID).sorted()
        if listener != nil, keys == listenerKeys { return }
        listener?.cancel()
        listener = nil
        let candidates = (listenerPort != 0 ? [listenerPort] : []) + (0..<10).map { Self.basePort + UInt16($0) }
        for port in candidates {
            do {
                let l = try NWListener(using: SyncTLS.serverParameters(me: identity, peers: syncPeers()), on: NWEndpoint.Port(rawValue: port)!)
                l.newConnectionHandler = { [engine] c in engine.attach(c, to: nil) }
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    let once = Once()
                    l.stateUpdateHandler = { state in
                        switch state {
                        case .ready: once.run { cont.resume() }
                        case .failed(let e), .waiting(let e): once.run { cont.resume(throwing: e) }
                        default: break
                        }
                    }
                    l.start(queue: DispatchQueue(label: "iNAS.sync.listen"))
                }
                listener = l
                listenerKeys = keys
                if listenerPort != port { note("TCP \(port) 에서 대기 중 (암호화, 기기 \(keys.count)대의 키)") }
                listenerPort = port
                me.internalPort = Int(port)
                listenStatus = "TCP \(port) 에서 대기 중 (암호화)"
                return
            } catch {
                listenStatus = "TCP \(port) 대기 실패: \(error.localizedDescription)"
            }
        }
        note(listenStatus)
    }

    /// 공개 키가 있는 다른 기기
    private func syncPeer(_ d: SyncDevice) -> SyncPeer? {
        guard let k = Data(base64Encoded: d.publicKey), k.count == 32 else { return nil }
        let p = SyncPeer(publicKey: k, name: d.name)
        return blocked[p.keyID] == nil ? p : nil
    }

    private func syncPeers() -> [SyncPeer] { peers.compactMap(syncPeer) }

    private func deviceID(forKey keyID: String) -> String? {
        peers.first { syncPeer($0)?.keyID == keyID }?.id
    }

    private func engineStatus(_ st: [String: SyncFolderStatus]) {
        folderStatus = st
        me.folders = st.mapValues { SyncDeviceFolder(state: $0.state.rawValue, needItems: $0.needItems, lastSync: $0.lastSync) }
    }

    // MARK: 앱 창에 보낼 상태

    func snapshot() -> SyncSnapshot {
        let inb = inboundSummary
        return SyncSnapshot(
            me: me,
            peers: peers.map { d in
                let key = Data(base64Encoded: d.publicKey).flatMap { $0.count == 32 ? SyncIdentity.keyID(of: $0) : nil }
                let isBlocked = key.map { blocked[$0] != nil } ?? false
                return SyncSnapshot.Peer(device: d, role: isBlocked ? "차단됨" : (key == nil ? "연결 안 함 (저쪽 iNAS 가 옛 버전이라 공개 키가 없음)" : role(for: d).text),
                                         blockedKey: isBlocked ? key : nil, keyID: key)
            },
            blocked: blocked.values.sorted { $0.revokedAt > $1.revokedAt },
            listenStatus: listenStatus, stunStatus: stunStatus, iCloudStatus: iCloudStatus, iCloudOK: iCloudOK,
            inboundOK: inb.ok, inboundText: inb.text, folderStatus: folderStatus, busy: busy,
            log: log.prefix(60).map { SyncSnapshot.LogLine(date: $0.0, text: $0.1) }
        )
    }

    // MARK: 기기 지우기 · 차단

    /// 기기 지우기: 그 기기의 키를 차단 목록에 올리고 기기 기록을 지운다. 연결은 바로 끊는다.
    /// (그 Mac 이 옛 앱으로 기록을 다시 올려도 이 키는 믿지 않는다. 실수면 restoreDevice)
    func removeDevice(_ deviceID: String) async {
        guard let d = allDevices[deviceID], d.id != me.id else { return }
        do {
            if let k = Data(base64Encoded: d.publicKey), k.count == 32 {
                let keyID = SyncIdentity.keyID(of: k)
                let rec = CKRecord(recordType: Self.blockRecordType, recordID: CKRecord.ID(recordName: keyID, zoneID: Self.zoneID))
                rec["name"] = d.name
                rec["revokedAt"] = Date()
                try await Self.saveChecked(rec, in: database)
                blocked[keyID] = SyncBlockedDevice(keyID: keyID, name: d.name, revokedAt: Date())
            }
            _ = try await database.modifyRecords(saving: [], deleting: [CKRecord.ID(recordName: d.id, zoneID: Self.zoneID)])
            allDevices[d.id] = nil
            me.links[d.id] = nil
            note("\(d.name) 기기를 지우고 키를 차단함")
            applyPeers(force: true)
        } catch {
            note("\(d.name) 기기 지우기 실패: \(error.localizedDescription)")
        }
    }

    /// 차단 풀기 (그 기기가 다시 기록을 올리면 믿는다)
    func restoreDevice(_ keyID: String) async {
        do {
            _ = try await database.modifyRecords(saving: [], deleting: [CKRecord.ID(recordName: keyID, zoneID: Self.zoneID)])
            let name = blocked[keyID]?.name ?? "?"
            blocked[keyID] = nil
            note("\(name) 차단을 풂")
            applyPeers(force: true)
        } catch {
            note("차단 풀기 실패: \(error.localizedDescription)")
        }
    }

    /// 기기 목록 · 키가 바뀌면 엔진이 믿을 기기와 대기(TLS 키 목록)를 바꾼다
    private func applyPeers(force: Bool = false) {
        peers = allDevices.values.filter { $0.id != me.id }.sorted { $0.name < $1.name }
        let keys = syncPeers().map(\.keyID).sorted()
        guard force || keys != listenerKeys else { return }
        let list = syncPeers()
        Task {
            await engine.setPeers(list)
            await ensureListening()
        }
    }

    /// 무작위 아이디를 쓰던 옛 빌드의 내 기록을 지운다 (하드웨어 기준 아이디로 바꿈)
    private func cleanOldRecord() async {
        guard !cleanedOldRecord else { return }
        cleanedOldRecord = true
        guard let old = Prefs.defaults.string(forKey: "syncDeviceID"), old != me.id else { return }
        do {
            _ = try await database.modifyRecords(saving: [], deleting: [CKRecord.ID(recordName: old, zoneID: Self.zoneID)])
            Prefs.defaults.removeObject(forKey: "syncDeviceID")
            allDevices[old] = nil
            note("옛 기기 기록(\(old.prefix(8))…)을 지움")
        } catch {
            note("옛 기기 기록 지우기 실패: \(error.localizedDescription)")
        }
    }

    // MARK: 폴더

    /// 이 Mac 에서 켜진 폴더 (AppModel 이 SyncFolderStore 를 보고 넘김)
    func setFolders(_ configs: [SyncFolderConfig]) {
        guard configs != folderConfigs else { return }
        folderConfigs = configs
        Task { await engine.configure(folders: configs) }
        let ids = Set(configs.map(\.id))
        for id in watchers.keys where !ids.contains(id) { watchers[id] = nil }
        for c in configs where watchers[c.id]?.path != c.path {
            let id = c.id
            watchers[id] = SyncWatcher(path: c.path) { [engine] paths in
                Task { await engine.requestScan(id, paths.contains("") ? nil : paths) }
            }
        }
    }

    // MARK: 포트 열기

    private func openPort() async {
        guard me.internalPort != 0 else {
            me.portMethod = "대기 못 함"
            me.reachable = false
            return
        }
        if !me.localIP.isEmpty, !DeviceInfo.isPrivate(me.localIP) {
            me.port = me.internalPort
            me.portMethod = "공인 IP 바로 (공유기 없음, 방화벽은 붙어 봐야 앎)"
            me.reachable = true
            return
        }
        do {
            if gateway == nil {
                gateway = try await UPnP.findGateway()
                note("공유기 찾음: \(gateway!.name)")
            }
            guard let gw = gateway else { return }
            let wan = try await UPnP.externalIP(gw)
            var opened: UInt16?
            var lastError: Error?
            for offset in 0..<5 {
                let ext = UInt16(me.internalPort) + UInt16(offset)
                if let owner = await UPnP.mappingClient(gw, external: ext),
                   owner.client != me.localIP || owner.port != "\(me.internalPort)" {
                    continue  // 다른 기기가 쓰는 바깥 포트
                }
                do {
                    try await UPnP.addMapping(gw, external: ext, internal: UInt16(me.internalPort), client: me.localIP, lease: 3600)
                    opened = ext
                    break
                } catch { lastError = error }
            }
            guard let ext = opened else { throw lastError ?? NetError("빈 바깥 포트가 없음") }
            if mappedExternal != ext { note("공유기 포트 열기: 바깥 \(ext) → \(me.localIP):\(me.internalPort)") }
            mappedExternal = ext
            me.port = Int(ext)
            var method = "UPnP (\(gw.name))"
            if !me.publicIP.isEmpty, wan != me.publicIP {
                method += " · 공유기 바깥 IP \(wan) 가 공인 IP 와 다름 (공유기 뒤에 또 NAT)"
                me.reachable = false
            } else {
                me.reachable = true
            }
            me.portMethod = method
        } catch {
            gateway = nil
            me.port = me.internalPort
            me.reachable = false
            let text = "열지 못함: \(error.localizedDescription)"
            if me.portMethod != text { note("포트 \(text)") }
            me.portMethod = text
        }
    }

    /// 앱이 끝날 때 공유기 포트를 닫는다 (못 닫아도 1시간 뒤 풀린다)
    private func closePortSync() {
        guard let gw = gateway, let ext = mappedExternal else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await UPnP.deleteMapping(gw, external: ext)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)
    }

    // MARK: iCloud (CloudKit 개인 DB, Sync 영역에 기기마다 기록 하나)

    /// 바뀐 기록만 받고(변경 토큰), 내 기록은 바뀌었거나 1분 지났으면 올린다
    func pollICloud(forceSave: Bool = false) async {
        // 겹쳐 부르면 끝난 뒤 한 번 더
        if iCloudBusy {
            iCloudAgain = true
            iCloudAgainForce = iCloudAgainForce || forceSave
            return
        }
        iCloudBusy = true
        await pollICloudOnce(forceSave: forceSave)
        while iCloudAgain {
            let force = iCloudAgainForce
            iCloudAgain = false
            iCloudAgainForce = false
            await pollICloudOnce(forceSave: force)
        }
        iCloudBusy = false
    }

    private func pollICloudOnce(forceSave: Bool) async {
        do {
            if !zoneReady {
                let status = try await CKContainer(identifier: Self.containerID).accountStatus()
                guard status == .available else {
                    iCloudOK = false
                    iCloudStatus = "iCloud 를 쓸 수 없음 (\(status.rawValue)) — 시스템 설정에서 iCloud 로그인 확인"
                    note(iCloudStatus)
                    return
                }
                _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
                zoneReady = true
            }
            try await fetchChanges()
            await cleanOldRecord()
            // 내 기록을 못 올려도 다른 기기 목록은 반영한다
            applyPeers()
            me.links = me.links.filter { id, _ in allDevices[id] != nil }
            me.appVersion = AppVersion.text
            var compare = me
            compare.updatedAt = lastSaved?.updatedAt ?? .distantPast
            if forceSave || compare != lastSaved || Date().timeIntervalSince(lastSavedAt) > 60 {
                me.updatedAt = Date()
                try await save(me)
                lastSaved = me
                lastSavedAt = Date()
            }
            iCloudOK = true
            iCloudStatus = "올림 · 기기 \(allDevices.count)대 (내 기록 포함)"
        } catch {
            iCloudOK = false
            iCloudStatus = "iCloud 오류: \(error.localizedDescription)"
            note(iCloudStatus)
            if let ck = error as? CKError, ck.code == .changeTokenExpired { changeToken = nil }
        }
    }

    private func fetchChanges() async throws {
        while true {
            let r = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: changeToken)
            for (_, result) in r.modificationResultsByID {
                guard case .success(let m) = result else { continue }
                if let d = Self.device(from: m.record) {
                    if allDevices[d.id] == nil, d.id != me.id { note("iCloud 에서 \(d.name) 찾음") }
                    allDevices[d.id] = d
                } else if m.record.recordType == Self.blockRecordType {
                    let b = SyncBlockedDevice(keyID: m.record.recordID.recordName, name: m.record["name"] as? String ?? "?",
                                              revokedAt: m.record["revokedAt"] as? Date ?? Date())
                    blocked[b.keyID] = b
                }
            }
            for deletion in r.deletions {
                if deletion.recordType == Self.blockRecordType {
                    blocked[deletion.recordID.recordName] = nil
                } else {
                    allDevices[deletion.recordID.recordName] = nil
                }
            }
            changeToken = r.changeToken
            if !r.moreComing { break }
        }
    }

    private func save(_ d: SyncDevice) async throws {
        try await Self.saveChecked(Self.record(from: d), in: database)
    }

    /// modifyRecords 는 기록 하나하나의 실패를 던지지 않고 결과에 담으므로 꺼내서 던진다
    nonisolated private static func saveChecked(_ rec: CKRecord, in db: CKDatabase) async throws {
        let r = try await db.modifyRecords(saving: [rec], deleting: [], savePolicy: .allKeys, atomically: false)
        for (_, result) in r.saveResults {
            if case .failure(let e) = result { throw e }
        }
    }

    nonisolated private static func record(from d: SyncDevice) -> CKRecord {
        let rec = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: d.id, zoneID: Self.zoneID))
        rec["name"] = d.name
        rec["model"] = d.model
        rec["modelID"] = d.modelID
        rec["os"] = d.os
        rec["appVersion"] = d.appVersion
        rec["localIP"] = d.localIP
        rec["publicIP"] = d.publicIP
        rec["port"] = d.port
        rec["internalPort"] = d.internalPort
        rec["portMethod"] = d.portMethod
        rec["reachable"] = d.reachable ? 1 : 0
        rec["updatedAt"] = d.updatedAt
        rec["reach"] = String(decoding: (try? json.encode(d.links)) ?? Data("{}".utf8), as: UTF8.self)  // 칸 이름은 운영 스키마 그대로 reach
        rec["publicKey"] = d.publicKey
        rec["folders"] = String(decoding: (try? json.encode(d.folders)) ?? Data("{}".utf8), as: UTF8.self)
        return rec
    }

    nonisolated private static let json: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func device(from r: CKRecord) -> SyncDevice? {
        guard r.recordType == recordType else { return nil }
        let links = (r["reach"] as? String).flatMap { try? jsonDecoder.decode([String: SyncLinkInfo].self, from: Data($0.utf8)) } ?? [:]
        return SyncDevice(
            id: r.recordID.recordName, name: r["name"] as? String ?? "?", model: r["model"] as? String ?? "",
            modelID: r["modelID"] as? String ?? "", os: r["os"] as? String ?? "", appVersion: r["appVersion"] as? String ?? "",
            localIP: r["localIP"] as? String ?? "", publicIP: r["publicIP"] as? String ?? "",
            port: r["port"] as? Int ?? 0, internalPort: r["internalPort"] as? Int ?? 0,
            portMethod: r["portMethod"] as? String ?? "", reachable: (r["reachable"] as? Int ?? 0) != 0,
            updatedAt: r["updatedAt"] as? Date ?? .distantPast, links: links,
            publicKey: r["publicKey"] as? String ?? "",
            folders: (r["folders"] as? String).flatMap { try? jsonDecoder.decode([String: SyncDeviceFolder].self, from: Data($0.utf8)) } ?? [:]
        )
    }

    // MARK: 역할 · 연결 유지

    /// 같은 공유기 안이면 아이디 작은 쪽이 내부 주소로. 아니면 포트를 연 쪽이 기다리고 못 연 쪽이 붙는다.
    /// 둘 다 열렸으면 아이디 작은 쪽이 붙고, 90초 안에 안 붙으면 다른 쪽도 붙어 본다.
    func role(for peer: SyncDevice) -> SyncRole {
        if Date().timeIntervalSince(peer.updatedAt) > Self.staleAfter { return .none(reason: "\(peer.name) 소식 없음") }
        if me.internalPort == 0 { return .none(reason: "나는 대기 못 함") }
        let iAmFirst = me.id < peer.id
        if !peer.publicIP.isEmpty, peer.publicIP == me.publicIP, !peer.localIP.isEmpty, peer.internalPort > 0 {
            let dial = SyncRole.dial(host: peer.localIP, port: peer.internalPort, via: "내부 \(peer.localIP):\(peer.internalPort)", reason: "같은 공유기 안")
            return iAmFirst || waitedTooLong(peer) ? dial : .wait(reason: "같은 공유기 안 · 저쪽 차례")
        }
        guard !peer.publicIP.isEmpty, peer.port > 0 else {
            return me.reachable ? .wait(reason: "저쪽 주소를 모름") : .none(reason: "저쪽 주소를 모름")
        }
        let dial = SyncRole.dial(host: peer.publicIP, port: peer.port, via: "외부 \(peer.publicIP):\(peer.port)", reason: "")
        func withReason(_ r: String) -> SyncRole {
            if case .dial(let h, let p, let v, _) = dial { return .dial(host: h, port: p, via: v, reason: r) }
            return dial
        }
        // 짐작(포트를 열었다/공인 IP 다)보다 실제로 붙어 본 결과가 먼저다
        let meIn = inbound(from: peer)
        let peerIn = outbound(to: peer)
        let meOpen = meIn.evidence ?? me.reachable
        let peerOpen = peerIn.evidence ?? peer.reachable
        switch (meOpen, peerOpen) {
        case (false, true):
            return withReason(meIn.evidence == false ? "저쪽이 나에게 못 붙음" : "저쪽만 포트가 열림")
        case (true, false):
            return .wait(reason: peerIn.evidence == false ? "내가 저쪽에 못 붙음" : "나만 포트가 열림")
        case (true, true):
            if meIn.evidence == true, peerIn.evidence != true { return .wait(reason: "저쪽이 나에게 붙은 적 있음") }
            if peerIn.evidence == true, meIn.evidence != true { return withReason("내가 저쪽에 붙은 적 있음") }
            if iAmFirst { return withReason("둘 다 열림 · 내 차례") }
            return waitedTooLong(peer) ? withReason("저쪽이 안 붙어 와서") : .wait(reason: "둘 다 열림 · 저쪽 차례")
        case (false, false):
            return .none(reason: "둘 다 들어오는 연결이 막혀 중계가 필요")
        }
    }

    /// 이 정도 지난 실패는 잊고 다시 해 본다 (주소가 바뀌면 시간과 상관없이 바로 잊는다)
    static let evidenceTTL: TimeInterval = 10 * 60

    /// 붙어 본 기록이 지금 이 주소에 대한 것인지 ("외부 1.2.3.4:47731" / "내부 192.168.0.5:47731")
    private static func link(_ l: SyncLinkInfo, isFor d: SyncDevice) -> Bool {
        l.via == "외부 \(d.publicIP):\(d.port)" || l.via == "내부 \(d.localIP):\(d.internalPort)"
    }

    /// 저쪽이 나에게 붙어 본 결과 (true 붙음, false 못 붙음, nil 모름) — 저쪽 기록과 지금 받은 연결로.
    /// 저쪽이 붙어 본 주소가 지금 내 주소와 다르면(내가 다른 망으로 옮김) 그 기록은 버린다.
    func inbound(from peer: SyncDevice) -> (evidence: Bool?, text: String) {
        if let sp = syncPeer(peer), engineLinks[sp.keyID] != nil, me.links[peer.id]?.outgoing == false { return (true, "\(peer.name) 이 붙어 와 있음") }
        guard let l = peer.links[me.id], l.outgoing else { return (nil, "아직 아무도 붙어 보지 않음") }
        guard Self.link(l, isFor: me) else { return (nil, "내 주소가 바뀌어 다시 확인 필요") }
        let fresh = Date().timeIntervalSince(l.at) < Self.evidenceTTL
        if l.up { return (true, "\(peer.name) 이 붙음") }
        // 붙었다가 끊긴 것(앱 재시작 등)은 못 붙은 게 아니다. 붙어 본 적 없는 실패만 lastSeen 이 없다
        if l.lastSeen != nil { return (true, "\(peer.name) 이 붙은 적 있음") }
        // 닿았는데 손잡기 · 인사에서 끊긴 것(옛 빌드 · 키가 다름)은 길이 막힌 게 아니다
        if fresh, FrameConnection.isUnreachable(l.error) { return (false, "\(peer.name) 이 못 붙음: \(l.error ?? "")") }
        if fresh { return (nil, "\(peer.name) 이 닿았지만 손잡기 실패: \(l.error ?? "")") }
        return (nil, "오래전 실패라 다시 확인 필요")
    }

    /// 내가 저쪽에 붙어 본 결과. 저쪽 주소가 바뀌었으면(다른 망으로 옮김) 기록을 버린다.
    func outbound(to peer: SyncDevice) -> (evidence: Bool?, text: String) {
        guard let l = me.links[peer.id], l.outgoing else { return (nil, "") }
        guard Self.link(l, isFor: peer) else { return (nil, "저쪽 주소가 바뀜") }
        if l.up || l.lastSeen != nil { return (true, "") }
        if Date().timeIntervalSince(l.at) < Self.evidenceTTL, FrameConnection.isUnreachable(l.error) { return (false, l.error ?? "") }
        return (nil, "")
    }

    /// 내 공인 IP 가 바뀌면(다른 망) 내가 붙어 본 실패 기록과 다시 붙기 대기를 지운다
    private func networkChanged() {
        me.links = me.links.filter { $0.value.up }
        nextDial = [:]
        dialFailures = [:]
        waitingSince = [:]
    }

    /// 화면용: 바깥에서 나에게 붙을 수 있는지 — 다른 기기가 실제로 붙어 본 결과
    var inboundSummary: (ok: Bool?, text: String) {
        var results: [(Bool?, String)] = peers.map { inbound(from: $0) }.map { ($0.evidence, $0.text) }
        results = results.filter { $0.0 != nil }
        if let yes = results.first(where: { $0.0 == true }) { return (true, "확인됨 · \(yes.1)") }
        if let no = results.first { return (false, "막힘 · \(no.1)") }
        return (nil, "확인 전 (다른 기기가 붙어 봐야 앎)")
    }

    static let waitGiveUp: TimeInterval = 3 * 60

    private func fallbackTarget(_ peer: SyncDevice) -> (host: String, port: Int, via: String)? {
        if !peer.publicIP.isEmpty, peer.publicIP == me.publicIP, !peer.localIP.isEmpty, peer.internalPort > 0 {
            return (peer.localIP, peer.internalPort, "내부 \(peer.localIP):\(peer.internalPort)")
        }
        guard !peer.publicIP.isEmpty, peer.port > 0 else { return nil }
        return (peer.publicIP, peer.port, "외부 \(peer.publicIP):\(peer.port)")
    }

    private func waitedTooLong(_ peer: SyncDevice) -> Bool {
        guard let since = waitingSince[peer.id] else { return false }
        return Date().timeIntervalSince(since) > 90
    }

    /// 5초마다: 역할대로 붙는다 (신호 · 끊김 판단은 엔진이 한다)
    func manageLinks() {
        let now = Date()
        for peer in peers {
            guard let sp = syncPeer(peer) else { continue }
            if engineLinks[sp.keyID] != nil {
                waitingSince[peer.id] = nil
                continue
            }
            let r = role(for: peer)
            if case .wait = r {
                if waitingSince[peer.id] == nil { waitingSince[peer.id] = now }
            } else {
                waitingSince[peer.id] = nil
            }
            let ready = !dialingIDs.contains(peer.id) && (nextDial[peer.id] ?? .distantPast) <= now
            if case .dial(let host, let port, let via, _) = r, ready {
                dial(peer, host: host, port: port, via: via)
            } else if case .wait = r, let since = waitingSince[peer.id], now.timeIntervalSince(since) > Self.waitGiveUp,
                      ready, let target = fallbackTarget(peer) {
                // 서로 기다리는 일이 없게: 3분 넘게 안 붙어 오면 나도 붙어 본다
                note("\(peer.name) 이 \(Int(Self.waitGiveUp / 60))분 넘게 안 붙어 와서 내가 붙어 봄")
                waitingSince[peer.id] = now
                dial(peer, host: target.host, port: target.port, via: target.via)
            }
        }
        dumpForDebug()
    }

    private func dial(_ peer: SyncDevice, host: String, port: Int, via: String) {
        guard let sp = syncPeer(peer), let params = try? SyncTLS.clientParameters(me: identity, peer: sp),
              let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        dialingIDs.insert(peer.id)
        outgoingKeys.insert(sp.keyID)
        let started = Date()
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        engine.attach(c, to: sp) { [weak self] error in
            Task { @MainActor in self?.dialFinished(peer, key: sp.keyID, via: via, started: started, error: error) }
        }
    }

    private func dialFinished(_ peer: SyncDevice, key: String, via: String, started: Date, error: String?) {
        dialingIDs.remove(peer.id)
        if let error {
            if engineLinks[key] == nil { outgoingKeys.remove(key) }
            let fails = (dialFailures[peer.id] ?? 0) + 1
            dialFailures[peer.id] = fails
            let wait = min(60, 5 * fails)
            nextDial[peer.id] = Date().addingTimeInterval(TimeInterval(wait))
            if me.links[peer.id]?.error != error || me.links[peer.id]?.up == true {
                note("\(peer.name) 에 못 붙음 — \(via): \(error) (\(wait)초 뒤 다시)")
            }
            if engineLinks[key] == nil {
                me.links[peer.id] = SyncLinkInfo(up: false, outgoing: true, via: via, since: nil, lastSeen: nil, rtt: nil, error: error, at: Date())
            }
        } else {
            dialFailures[peer.id] = 0
            let rtt = Int(Date().timeIntervalSince(started) * 1000)
            me.links[peer.id] = SyncLinkInfo(up: true, outgoing: true, via: via, since: Date(), lastSeen: Date(), rtt: rtt, error: nil, at: Date())
            note("\(peer.name) 에 붙음 — \(via) (\(rtt)ms, 암호화)")
        }
        Task { await pollICloud() }
    }

    /// 엔진 연결이 생기거나 끊기거나 신호가 올 때
    private func linksChanged(_ list: [SyncPeerLink]) {
        let new = Dictionary(list.map { ($0.keyID, $0) }, uniquingKeysWith: { a, _ in a })
        for (key, old) in engineLinks where new[key] == nil {
            let out = outgoingKeys.contains(key)
            outgoingKeys.remove(key)
            guard let id = deviceID(forKey: key) else { continue }
            nextDial[id] = Date().addingTimeInterval(3)
            note("\(old.name) 연결 끊김")
            me.links[id] = SyncLinkInfo(up: false, outgoing: out, via: me.links[id]?.via ?? old.remote, since: nil,
                                        lastSeen: old.lastSeen, rtt: nil, error: "끊김", at: Date())
        }
        for (key, l) in new {
            guard let id = deviceID(forKey: key) else { continue }
            let out = outgoingKeys.contains(key)
            if engineLinks[key] == nil, !out { note("\(l.name) 이(가) 붙어 옴 — \(l.remote) (암호화)") }
            let info = me.links[id]
            me.links[id] = SyncLinkInfo(up: true, outgoing: out, via: out ? (info?.via ?? l.remote) : l.remote,
                                        since: l.since, lastSeen: l.lastSeen, rtt: l.rtt ?? info?.rtt, error: nil,
                                        at: info?.up == true ? info!.at : Date())
        }
        let changed = Set(new.keys) != Set(engineLinks.keys)
        engineLinks = new
        if changed { Task { await pollICloud() } }
    }

    // MARK: 스키마 만들기 (개발 환경 한 번)

    /// `iNAS --sync-schema`: 개발 서명 빌드로 한 번 돌려 CloudKit 개발 환경에 Sync 영역 · SyncDevice 형식을 만든다.
    /// Developer ID 앱은 운영 환경만 쓸 수 있어서, 그다음 CloudKit 콘솔에서 운영으로 올려야(Deploy Schema Changes) 한다.
    nonisolated static let schemaArgument = "--sync-schema"

    nonisolated static func runSchemaSeed() -> Never {
        Task.detached {
            do {
                let db = CKContainer(identifier: containerID).privateCloudDatabase
                _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
                let seed = SyncDevice(
                    id: "schema-seed", name: "seed", model: "seed", modelID: "seed", os: "seed", appVersion: "seed",
                    localIP: "0.0.0.0", publicIP: "0.0.0.0", port: 1, internalPort: 1, portMethod: "seed", reachable: true,
                    updatedAt: Date(), links: ["x": SyncLinkInfo(up: true, outgoing: true, via: "seed", at: Date())],
                    publicKey: "seed",
                    folders: ["seed": SyncDeviceFolder(state: "idle", needItems: 0, lastSync: Date())]
                )
                try await saveChecked(record(from: seed), in: db)
                _ = try await db.modifyRecords(saving: [], deleting: [CKRecord.ID(recordName: seed.id, zoneID: zoneID)])
                let folder = SyncFolder(id: "schema-seed-folder", name: "seed")
                try await SyncFolderStore.save(folder, in: db)
                _ = try await db.modifyRecords(saving: [], deleting: [CKRecord.ID(recordName: folder.id, zoneID: zoneID)])
                let block = CKRecord(recordType: blockRecordType, recordID: CKRecord.ID(recordName: "schema-seed-block", zoneID: zoneID))
                block["name"] = "seed"
                block["revokedAt"] = Date()
                try await saveChecked(block, in: db)
                _ = try await db.modifyRecords(saving: [], deleting: [block.recordID])
                print("스키마 만듦: 영역 Sync · 형식 \(recordType), \(SyncFolderStore.recordType), \(blockRecordType)")
                exit(0)
            } catch {
                print("스키마 실패: \(error)")
                exit(1)
            }
        }
        dispatchMain()
    }

    // MARK: 기록

    private func note(_ text: String) {
        log.insert((Date(), text), at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
        Log.app.info("sync: \(text, privacy: .public)")
    }

    /// 시험용: `defaults write com.moimz.iNAS syncDebugDumpDir <폴더>` 를 해 두면 상태를 <폴더>/<이름>.json 으로 쓴다
    /// 30초에 한 번만 쓴다. 5초마다 다시 쓰면 Syncthing 이 옮기는 도중 파일이 바뀌어 끝내 못 넘긴다(.syncthing.*.tmp 만 남음).
    private func dumpForDebug() {
        guard let dir = Prefs.defaults.string(forKey: "syncDebugDumpDir"), !dir.isEmpty else { return }
        guard Date().timeIntervalSince(lastDump) >= 30 else { return }
        lastDump = Date()
        struct Dump: Encodable {
            var at: Date
            var me: SyncDevice
            var peers: [SyncDevice]
            var roles: [String: String]
            var listen, stun, iCloud: String
            var folders: [String: SyncFolderStatus]
            var log: [String]
        }
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        let dump = Dump(
            at: Date(), me: me, peers: peers,
            roles: Dictionary(uniqueKeysWithValues: peers.map { ("\($0.name) \($0.id.prefix(8))", role(for: $0).text) }),
            listen: listenStatus, stun: stunStatus, iCloud: iCloudStatus,
            folders: folderStatus,
            log: log.map { "\(f.string(from: $0.0)) \($0.1)" }
        )
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(dump) else { return }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("\(me.name).json")
        try? data.write(to: url, options: .atomic)
    }
}
