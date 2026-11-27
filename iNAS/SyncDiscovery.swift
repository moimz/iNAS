import AppKit
import CloudKit
import Foundation

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
    /// 이 기기가 다른 기기(아이디)에 붙어 본 결과
    var reach: [String: SyncReach]
}

struct SyncReach: Codable, Equatable {
    var ok: Bool
    var at: Date
    var ms: Int
    /// "외부 1.2.3.4:47731", "내부 192.168.0.5:47731"
    var via: String
    var error: String?
}

/// 설정 > 동기화 (시험): 기기 정보 · 공인 IP · 포트 열기 · 대기 · iCloud 등록 · 서로 연결 확인.
/// 앱이 떠 있는 동안 1분마다 돈다.
@MainActor
final class SyncDiscovery: ObservableObject {
    nonisolated static let containerID = "iCloud.com.moimz.iNAS"
    nonisolated static let recordType = "SyncDevice"
    static let basePort: UInt16 = 47731
    nonisolated private static let zoneID = CKRecordZone.ID(zoneName: "Sync", ownerName: CKCurrentUserDefaultName)

    @Published private(set) var me: SyncDevice
    @Published private(set) var peers: [SyncDevice] = []
    /// 받은 인사: 기기 아이디 → (시각, 보낸 쪽 주소)
    @Published private(set) var inbound: [String: (Date, String)] = [:]
    @Published private(set) var listenStatus = "시작 전"
    @Published private(set) var stunStatus = ""
    @Published private(set) var iCloudStatus = "확인 전"
    @Published private(set) var iCloudOK = false
    @Published private(set) var busy = false
    @Published private(set) var lastRun: Date?
    @Published private(set) var log: [(Date, String)] = []

    private let listener = SyncListener()
    private var gateway: UPnPGateway?
    private var mappedExternal: UInt16?
    private var timer: Timer?
    private var zoneReady = false
    private lazy var database = CKContainer(identifier: Self.containerID).privateCloudDatabase

    init() {
        let key = "syncDeviceID"
        let id = UserDefaults.standard.string(forKey: key) ?? {
            let new = UUID().uuidString
            UserDefaults.standard.set(new, forKey: key)
            return new
        }()
        me = SyncDevice(
            id: id, name: DeviceInfo.computerName, model: DeviceInfo.productName ?? DeviceInfo.modelIdentifier,
            modelID: DeviceInfo.modelIdentifier, os: DeviceInfo.osVersion, appVersion: AppVersion.text,
            localIP: "", publicIP: "", port: 0, internalPort: 0, portMethod: "", reachable: false,
            updatedAt: .distantPast, reach: [:]
        )
        listener.me = { [id] in SyncHello(id: id, name: DeviceInfo.computerName) }
        listener.onHello = { [weak self] hello, remote in
            Task { @MainActor in self?.received(hello, from: remote) }
        }
    }

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePortSync() }
        }
    }

    /// 한 바퀴: 내 정보 → 대기 → 공인 IP → 포트 열기 → iCloud 목록 → 다른 기기에 붙어 보기 → 내 기록 올리기
    func refresh() async {
        guard !busy else { return }
        busy = true
        defer {
            busy = false
            lastRun = Date()
            dumpForDebug()
        }
        me.name = DeviceInfo.computerName
        me.localIP = DeviceInfo.primaryIPv4() ?? ""

        await ensureListening()

        do {
            let r = try await STUN.publicAddress()
            if r.ip != me.publicIP { note("공인 IP \(r.ip) (STUN \(r.server))") }
            me.publicIP = r.ip
            stunStatus = "STUN \(r.server)"
        } catch {
            stunStatus = "공인 IP 를 못 알아냄: \(error.localizedDescription)"
            note(stunStatus)
        }

        await openPort()
        await syncWithICloud()
    }

    // MARK: 대기

    private func ensureListening() async {
        if listener.port != 0, me.internalPort == Int(listener.port) { return }
        for offset in 0..<10 {
            let port = Self.basePort + UInt16(offset)
            do {
                try await listener.start(port: port)
                me.internalPort = Int(port)
                listenStatus = "TCP \(port) 에서 대기 중"
                note(listenStatus)
                return
            } catch {
                listenStatus = "TCP \(port) 대기 실패: \(error.localizedDescription)"
            }
        }
        note(listenStatus)
    }

    private func received(_ hello: SyncHello, from remote: String) {
        let first = inbound[hello.id] == nil
        inbound[hello.id] = (Date(), remote)
        if first { note("\(hello.name) 에게서 연결 받음 (\(remote))") }
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
            me.portMethod = "공인 IP 바로 (공유기 없음)"
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

    private func syncWithICloud() async {
        do {
            let status = try await CKContainer(identifier: Self.containerID).accountStatus()
            guard status == .available else {
                iCloudOK = false
                iCloudStatus = "iCloud 를 쓸 수 없음 (\(status.rawValue)) — 시스템 설정에서 iCloud 로그인 확인"
                note(iCloudStatus)
                return
            }
            if !zoneReady {
                _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
                zoneReady = true
            }
            let all = try await fetchDevices()
            let others = all.filter { $0.id != me.id }.sorted { $0.name < $1.name }
            for peer in others where Date().timeIntervalSince(peer.updatedAt) < 15 * 60 {
                await probe(peer)
            }
            me.reach = me.reach.filter { id, _ in others.contains { $0.id == id } }
            me.updatedAt = Date()
            me.appVersion = AppVersion.text
            try await save(me)
            peers = others
            iCloudOK = true
            iCloudStatus = "올림 · 기기 \(all.count)대 (내 기록 포함)"
        } catch {
            iCloudOK = false
            iCloudStatus = "iCloud 오류: \(error.localizedDescription)"
            note(iCloudStatus)
        }
    }

    private func fetchDevices() async throws -> [SyncDevice] {
        var token: CKServerChangeToken?
        var devices: [SyncDevice] = []
        while true {
            let r = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token)
            for (_, result) in r.modificationResultsByID {
                if case .success(let m) = result, let d = Self.device(from: m.record) { devices.append(d) }
            }
            token = r.changeToken
            if !r.moreComing { break }
        }
        return devices
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
        rec["reach"] = String(decoding: (try? json.encode(d.reach)) ?? Data("{}".utf8), as: UTF8.self)
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
        let reach = (r["reach"] as? String).flatMap { try? jsonDecoder.decode([String: SyncReach].self, from: Data($0.utf8)) } ?? [:]
        return SyncDevice(
            id: r.recordID.recordName, name: r["name"] as? String ?? "?", model: r["model"] as? String ?? "",
            modelID: r["modelID"] as? String ?? "", os: r["os"] as? String ?? "", appVersion: r["appVersion"] as? String ?? "",
            localIP: r["localIP"] as? String ?? "", publicIP: r["publicIP"] as? String ?? "",
            port: r["port"] as? Int ?? 0, internalPort: r["internalPort"] as? Int ?? 0,
            portMethod: r["portMethod"] as? String ?? "", reachable: (r["reachable"] as? Int ?? 0) != 0,
            updatedAt: r["updatedAt"] as? Date ?? .distantPast, reach: reach
        )
    }

    // MARK: 다른 기기에 붙어 보기

    /// 같은 공인 IP(같은 공유기 안)면 내부 주소로, 아니면 공인 IP:바깥 포트로
    private func probe(_ peer: SyncDevice) async {
        let sameLAN = !peer.publicIP.isEmpty && peer.publicIP == me.publicIP && !peer.localIP.isEmpty
        let host = sameLAN ? peer.localIP : peer.publicIP
        let port = sameLAN ? peer.internalPort : peer.port
        guard !host.isEmpty, port > 0 else { return }
        let via = "\(sameLAN ? "내부" : "외부") \(host):\(port)"
        let r = await SyncProbe.hello(host: host, port: UInt16(port), me: SyncHello(id: me.id, name: me.name))
        var reach = SyncReach(ok: r.ok, at: Date(), ms: r.ms, via: via, error: r.error)
        if r.ok, r.peer?.id != peer.id {
            reach.ok = false
            reach.error = "다른 기기가 답함 (\(r.peer?.name ?? "?"))"
        }
        if me.reach[peer.id]?.ok != reach.ok {
            note("\(peer.name) 에 연결 \(reach.ok ? "됨 (\(r.ms)ms)" : "실패: \(reach.error ?? "")") — \(via)")
        }
        me.reach[peer.id] = reach
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
                    updatedAt: Date(), reach: ["x": SyncReach(ok: true, at: Date(), ms: 1, via: "seed", error: nil)]
                )
                try await saveChecked(record(from: seed), in: db)
                _ = try await db.modifyRecords(saving: [], deleting: [CKRecord.ID(recordName: seed.id, zoneID: zoneID)])
                print("스키마 만듦: 영역 Sync · 형식 \(recordType)")
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

    /// 시험용: `defaults write com.moimz.iNAS syncDebugDumpDir <폴더>` 를 해 두면 한 바퀴마다 상태를 <폴더>/<이름>.json 으로 쓴다
    private func dumpForDebug() {
        guard let dir = UserDefaults.standard.string(forKey: "syncDebugDumpDir"), !dir.isEmpty else { return }
        struct Dump: Encodable {
            var at: Date
            var me: SyncDevice
            var peers: [SyncDevice]
            var inbound: [String: String]
            var listen, stun, iCloud: String
            var log: [String]
        }
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        let dump = Dump(
            at: Date(), me: me, peers: peers,
            inbound: inbound.mapValues { "\(f.string(from: $0.0)) \($0.1)" },
            listen: listenStatus, stun: stunStatus, iCloud: iCloudStatus,
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
