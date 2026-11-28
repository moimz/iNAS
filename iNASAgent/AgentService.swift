import AppKit
import Combine
import Foundation
import Network

// MARK: 상주 에이전트 (iNASAgent.app, 메뉴 막대)

/// 로그인 항목(LaunchAgent, KeepAlive)으로 늘 떠 있는 에이전트. 앱 안 `Contents/Library/LoginItems/iNASAgent.app`.
/// - 시작 시 자동 연결: 로그인(시작)할 때 고른 공유를 연결한다.
/// - 연결 해제 시 자동 연결: 깨어남 · 네트워크 변경 때 빠진 공유를 다시 연결하고,
///   공유가 빠질 때 서버가 응답하지 않으면(끊김) 서버가 돌아올 때까지 1분마다 다시 시도한다.
///   서버가 응답하는데 빠졌으면 직접 꺼낸 것으로 보고 다음 깨어남 · 네트워크 변경까지 그대로 둔다.
/// 연결은 본체(`iNAS --mount-only`)를 띄워서 한다(키체인 비밀번호는 본체 서명으로 읽는다).
/// 한 일은 기록으로 남겨 XPC 로 앱 창에 알린다. 나중에 동기화도 이 프로세스에 들어온다.
@MainActor
final class AgentService: NSObject {
    static let shared = AgentService()

    /// 무엇 때문에 확인하는지
    enum Trigger: Equatable {
        case start, wake, network, retry, manual

        var label: String {
            switch self {
            case .start: return "시작"
            case .wake: return "깨어남"
            case .network: return "네트워크 변경"
            case .retry: return "다시 시도"
            case .manual: return "지금 연결"
            }
        }

        /// 이 확인을 해도 되는지 (설정 > 서버 의 토글)
        var isAllowed: Bool {
            switch self {
            case .start: return ServerStore.loadAutoMountAtLogin()
            case .manual: return true
            default: return ServerStore.loadAutoRemount()
            }
        }
    }

    /// 상태가 바뀌었다 (메뉴 막대가 받는다)
    static let statusDidChange = Notification.Name("AgentServiceStatusDidChange")

    private(set) var status: AgentStatus
    private let listener = NSXPCListener(machServiceName: AgentXPC.machServiceName)
    private var clients: [NSXPCConnection] = []
    private let pathMonitor = NWPathMonitor()
    private var lastPathKey: String?
    private var pending: DispatchWorkItem?
    private var pendingTrigger: Trigger?
    /// 다시 연결 중에 또 일이 생기면 끝난 뒤 한 번 더 확인한다.
    private var recheckTrigger: Trigger?
    /// 지금 붙어 있는 SMB 마운트 (꺼낸 뒤에는 무엇이 빠졌는지 알 수 없으므로 미리 들고 있는다)
    private var mounts: [String: MountTable.Entry] = [:]
    /// 끊겨서 서버가 돌아오길 기다리는 서버
    private var waiting: Set<UUID> = []
    private var retryTimer: Timer?
    private var retryCount = 0
    /// 1분마다 60번(1시간) 해 보고 그만둔다.
    private static let retryLimit = 60

    /// 폴더 동기화 (iCloud 로 기기 찾기 · 암호화 연결 · 엔진). 앱 창은 XPC 로 상태만 받는다
    let sync = SyncDiscovery()
    /// 폴더 목록(iCloud, 읽기만) · 이 Mac 의 폴더 설정(앱과 같이 쓰는 설정)
    let folders = SyncFolderStore(readOnly: true)
    private var cancellables: Set<AnyCancellable> = []

    private static var runningBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    /// 에이전트를 품은 iNAS.app (…/iNAS.app/Contents/Library/LoginItems/iNASAgent.app 에서 네 단계 위)
    static let mainAppURL: URL = {
        var url = Bundle.main.bundleURL
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }()

    override init() {
        status = AgentStatus(build: Self.runningBuild, bundlePath: Self.mainAppURL.path, startedAt: Date())
        status.events = EventStore.load()
        super.init()
    }

    func start() {
        Log.app.info("에이전트 시작: 빌드 \(Self.runningBuild, privacy: .public)")
        listener.delegate = self
        listener.resume()
        refreshMounts()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AgentService.shared.schedule(.wake, after: 5) }
        }
        center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AgentService.shared.refreshMounts() }
        }
        center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { AgentService.shared.volumeDidUnmount(url) }
        }

        pathMonitor.pathUpdateHandler = { path in
            let key: String
            if path.status == .satisfied {
                // 같은 en0 이라도 다른 Wi-Fi 로 옮기면 게이트웨이가 바뀐다.
                key = (Set(path.availableInterfaces.map(\.name)).sorted() + path.gateways.map { "\($0)" }.sorted())
                    .joined(separator: ",")
            } else {
                key = "offline"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AgentService.shared.pathChanged(key) }
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))

        // 로그인(또는 업데이트 뒤 다시 뜬 것). 로그인 직후에는 네트워크가 늦을 수 있어 자식 쪽이 몇 번 다시 시도한다.
        schedule(.start, after: 1)
        startSync()
    }

    private func startSync() {
        sync.start()
        folders.start()
        Publishers.CombineLatest(folders.$folders, folders.$local)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                self.sync.setFolders(self.folders.engineConfigs())
            }
            .store(in: &cancellables)
        // 상태가 바뀌면 0.5초 모아 앱 창에 보낸다
        sync.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.broadcastSync() }
            .store(in: &cancellables)
    }

    func handle(_ command: SyncCommand) {
        switch command {
        case .refresh: Task { await sync.refresh() }
        case .reloadFolders:
            folders.reloadLocal()
            Task { await folders.poll() }
        case .removeDevice(let id): Task { await sync.removeDevice(id) }
        case .restoreDevice(let key): Task { await sync.restoreDevice(key) }
        case .rescan(let id): Task { await sync.engine.requestScan(id, nil) }
        case .rescanPeer(let id, let peer): Task { await sync.engine.askPeerRescan(id, peer: peer) }
        }
    }

    private func broadcastSync() {
        let data = sync.snapshot().encoded()
        for client in clients {
            (client.remoteObjectProxy as? INASAgentClientProtocol)?.syncDidChange(data)
        }
    }

    private func pathChanged(_ key: String) {
        defer { lastPathKey = key }
        // 처음 한 번은 지금 상태를 알려 주는 것이라 무시한다.
        guard let last = lastPathKey, last != key else { return }
        if key == "offline" {
            Log.app.info("네트워크 끊김")
            return
        }
        Log.app.info("네트워크 변경: \(key, privacy: .public)")
        schedule(.network, after: 3)
    }

    private func refreshMounts() {
        mounts = Dictionary(MountTable.smbMounts().map { ($0.mountPoint, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// 고른 공유가 빠졌다. 서버가 응답하면 직접 꺼낸 것, 응답하지 않으면 끊긴 것으로 본다.
    private func volumeDidUnmount(_ url: URL?) {
        let entry = url.flatMap { mounts[$0.path] }
        refreshMounts()
        guard let entry,
              let server = ServerStore.loadServers().first(where: { s in
                  s.enabled && s.host.caseInsensitiveCompare(entry.host) == .orderedSame
                      && s.shares.contains { $0.caseInsensitiveCompare(entry.share) == .orderedSame }
              })
        else { return }
        let name = "\(server.displayName) / \(entry.share)"
        Task {
            let reachable = await Mounter.isReachable(host: server.host, port: server.port ?? 445, timeout: 4)
            guard ServerStore.loadAutoRemount() else {
                self.record(.info, "\(name) 연결 해제 감지")
                return
            }
            if reachable {
                self.record(.info, "\(name) 연결 해제 감지 — 직접 꺼낸 것으로 보고 그대로 둡니다")
            } else {
                self.record(.warn, "\(name) 연결 해제 감지 — 서버 응답이 없어 돌아오면 다시 연결합니다")
                self.wait(for: server.id)
            }
        }
    }

    // MARK: 확인 · 다시 연결

    /// 깨어나면 알림이 몰려오므로 잠깐 모았다가 한 번만 확인한다. 이유는 처음 것을 남긴다.
    func schedule(_ trigger: Trigger, after delay: TimeInterval) {
        // 깨어남 · 네트워크 변경이면 동기화도 공인 IP · 포트 · 연결을 다시 본다
        if trigger == .wake || trigger == .network {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { Task { await AgentService.shared.sync.refresh() } }
            }
        }
        pending?.cancel()
        let first = pendingTrigger ?? trigger
        pendingTrigger = first
        let item = DispatchWorkItem {
            MainActor.assumeIsolated {
                let service = AgentService.shared
                service.pending = nil
                service.pendingTrigger = nil
                service.check(first)
            }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 메뉴 막대 › 서버 › 지금 연결
    func connectNow(_ serverID: UUID) {
        check(.manual, only: [serverID])
    }

    /// 켜 둔 서버의 고른 공유 가운데 빠진 것이 있으면 연결한다. 다시 시도는 기다리는 서버만 본다.
    private func check(_ trigger: Trigger, only: Set<UUID>? = nil) {
        exitIfAppReplaced()
        guard trigger.isAllowed else {
            Log.app.info("확인(\(trigger.label, privacy: .public)): 설정에서 꺼져 있어 건너뜀")
            return
        }

        var servers = ServerStore.loadServers().filter { $0.enabled && !$0.host.isEmpty && !$0.shares.isEmpty }
        if trigger == .retry { servers = servers.filter { waiting.contains($0.id) } }
        if let only { servers = servers.filter { only.contains($0.id) } }
        let current = MountTable.smbMounts()
        var targets: [ServerConfig] = []
        var missing: [String] = []
        for server in servers {
            let gone = server.shares.filter { share in !current.contains { $0.matches(host: server.host, share: share) } }
            if gone.isEmpty {
                waiting.remove(server.id)
                continue
            }
            targets.append(server)
            missing += gone.map { "\(server.displayName) / \($0)" }
        }
        Log.app.info("확인(\(trigger.label, privacy: .public)): 빠진 공유 \(missing.count)개")

        switch trigger {
        case .start:
            // 다 붙어 있으면(할 일 없음) 남기지 않는다. 끊김 · 다시 연결 · 실패만 남긴다 (사용자 2026-11-28)
            break
        case .wake, .network:
            if !missing.isEmpty { record(.info, "\(trigger.label): 빠진 공유 감지 — \(missing.joined(separator: ", "))") }
        case .manual:
            if missing.isEmpty { record(.info, "지금 연결: 공유가 모두 연결돼 있습니다") }
        case .retry:
            break
        }

        guard !targets.isEmpty else {
            stopRetryIfDone()
            return
        }
        if status.isRemounting {
            recheckTrigger = trigger
        } else {
            spawnMount(targets, trigger: trigger)
        }
    }

    /// 연결은 따로 프로세스(`--mount-only`)로 띄운다. 결과는 표준 출력의 JSON 으로 받는다.
    private func spawnMount(_ servers: [ServerConfig], trigger: Trigger) {
        let executable = Self.mainAppURL.appendingPathComponent("Contents/MacOS/iNAS")
        status.isRemounting = true
        broadcast()
        let ids = servers.map(\.id.uuidString).joined(separator: ",")
        let arguments = [MountCommand.argument, MountCommand.serversArgument, ids, MountCommand.reportArgument]

        DispatchQueue.global(qos: .utility).async {
            var results: [ServerResult] = []
            var failure: String?
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let lastLine = data.split(separator: UInt8(ascii: "\n")).last.map { Data($0) } ?? Data()
                if let decoded = try? JSONDecoder().decode([ServerResult].self, from: lastLine) {
                    results = decoded
                } else {
                    failure = "연결 프로세스의 결과를 읽지 못했습니다. (종료 코드 \(process.terminationStatus))"
                }
            } catch {
                failure = "연결 프로세스를 띄우지 못했습니다: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AgentService.shared.finishMount(results: results, failure: failure, trigger: trigger)
                }
            }
        }
    }

    private func finishMount(results: [ServerResult], failure: String?, trigger: Trigger) {
        status.isRemounting = false
        refreshMounts()
        let what = trigger == .start ? "시작 시 자동 연결" : trigger == .manual ? "지금 연결" : "자동 다시 연결"
        if let failure { record(.warn, "\(what) 실패: \(failure)") }
        for result in results {
            switch result.state {
            case .done:
                waiting.remove(result.serverID)
                let mounted = result.shares.filter { if case .mounted = $0.outcome { return true } else { return false } }
                if !mounted.isEmpty {
                    record(.ok, "\(what): \(result.serverName) / \(mounted.map(\.share).joined(separator: ", "))")
                }
                for share in result.shares {
                    if case .failed(let message) = share.outcome {
                        record(.warn, "\(result.serverName) / \(share.share) 연결 실패: \(message)")
                    }
                }
            case .unreachable:
                // 다시 시도에서는 1분마다 같은 줄이 쌓이지 않게 남기지 않는다.
                if trigger != .retry {
                    record(.warn, "\(what): \(result.serverName) 서버 응답 없음 — 돌아오면 다시 연결합니다")
                }
                if ServerStore.loadAutoRemount() { wait(for: result.serverID) }
            case .missingPassword:
                record(.warn, "\(result.serverName): 키체인에 비밀번호가 없습니다")
            case .nothingSelected:
                break
            }
        }
        stopRetryIfDone()
        broadcast()
        if let again = recheckTrigger {
            recheckTrigger = nil
            schedule(again, after: 1)
        }
    }

    // MARK: 서버가 돌아오길 기다리기

    private func wait(for id: UUID) {
        waiting.insert(id)
        guard retryTimer == nil else { return }
        retryCount = 0
        retryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { AgentService.shared.retryTick() }
        }
    }

    private func retryTick() {
        retryCount += 1
        if retryCount > Self.retryLimit {
            let names = ServerStore.loadServers().filter { waiting.contains($0.id) }.map(\.displayName)
            record(.warn, "\(names.joined(separator: ", ")): 1시간 동안 응답이 없어 다시 시도를 멈춥니다")
            waiting.removeAll()
            stopRetryIfDone()
            return
        }
        guard !status.isRemounting else { return }
        check(.retry)
    }

    private func stopRetryIfDone() {
        guard waiting.isEmpty else { return }
        retryTimer?.invalidate()
        retryTimer = nil
    }

    // MARK: 기록

    private func record(_ level: AgentEvent.Level, _ text: String) {
        Log.app.info("기록: \(text, privacy: .public)")
        status.events.insert(AgentEvent(date: Date(), level: level, text: text), at: 0)
        if status.events.count > EventStore.limit { status.events.removeLast(status.events.count - EventStore.limit) }
        EventStore.save(status.events)
        broadcast()
    }

    /// 앱이 새 버전으로 바뀌었으면(Sparkle 업데이트 등) 끝낸다. launchd 가 새 실행 파일로 다시 띄운다.
    private func exitIfAppReplaced() {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: url),
              let onDisk = info["CFBundleVersion"] as? String,
              onDisk != Self.runningBuild
        else { return }
        Log.app.info("앱이 빌드 \(onDisk, privacy: .public) 로 바뀌어 에이전트를 다시 띄웁니다.")
        exit(0)
    }

    // MARK: XPC

    fileprivate func add(_ connection: NSXPCConnection) {
        clients.append(connection)
    }

    fileprivate func remove(_ id: ObjectIdentifier) {
        clients.removeAll { ObjectIdentifier($0) == id }
    }

    private func broadcast() {
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
        let data = status.encoded()
        for client in clients {
            (client.remoteObjectProxy as? INASAgentClientProtocol)?.statusDidChange(data)
        }
    }

    fileprivate func restartForNewApp() {
        Log.app.info("앱이 새 버전이라 에이전트를 다시 띄웁니다.")
        exit(0)
    }
}

extension AgentService: NSXPCListenerDelegate {
    nonisolated func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(AgentXPC.appRequirement)
        connection.exportedInterface = AgentXPC.agentInterface()
        connection.exportedObject = AgentExport.forConnections
        connection.remoteObjectInterface = AgentXPC.clientInterface()
        let id = ObjectIdentifier(connection)
        connection.invalidationHandler = {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AgentService.shared.remove(id) }
            }
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AgentService.shared.add(connection) }
        }
        connection.resume()
        return true
    }
}

/// XPC 로 들어온 요청을 메인 스레드의 AgentService 로 넘긴다.
private final class AgentExport: NSObject, INASAgentProtocol {
    static let forConnections = AgentExport()

    func fetchStatus(reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { reply(AgentService.shared.status.encoded()) }
        }
    }

    func restart() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AgentService.shared.restartForNewApp() }
        }
    }

    func fetchSync(reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { reply(AgentService.shared.sync.snapshot().encoded()) }
        }
    }

    func fetchFolderDetail(_ folderID: String, peer: String, reply: @escaping (Data) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let engine = AgentService.shared.sync.engine
                if peer.isEmpty {
                    reply(engine.folderDetail(folderID).encoded())
                } else {
                    Task { reply(await engine.peerDetail(folderID, peer: peer)?.encoded() ?? Data()) }
                }
            }
        }
    }

    func syncCommand(_ data: Data) {
        guard let c = SyncCommand.decode(data) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AgentService.shared.handle(c) }
        }
    }
}

/// 기록을 파일에 남겨 에이전트가 다시 떠도(로그인 · 업데이트) 이어서 보여 준다.
/// ~/Library/Application Support/com.moimz.iNAS/agent-log.json
private enum EventStore {
    static let limit = 100

    private static var url: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("com.moimz.iNAS/agent-log.json")
    }

    static func load() -> [AgentEvent] {
        guard let url, let data = try? Data(contentsOf: url),
              let events = try? JSONDecoder().decode([AgentEvent].self, from: data)
        else { return [] }
        // 예전 빌드가 뜰 때마다 남기던 "할 일 없음" 줄은 걸러 낸다
        return events.filter { $0.text != "시작: 공유가 모두 연결돼 있습니다" }
    }

    static func save(_ events: [AgentEvent]) {
        guard let url, let data = try? JSONEncoder().encode(events) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
