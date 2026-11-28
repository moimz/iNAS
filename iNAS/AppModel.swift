import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let store = ServerStore()
    let loginItem = LoginItemController()
    /// 상주 에이전트(자동 연결) 상태와 기록
    let agent = AgentClient()
    /// 동기화 폴더 목록(iCloud) · 이 Mac 의 폴더 설정
    let folders = SyncFolderStore()

    /// 지금 붙어 있는 SMB 마운트 (로그인 항목 · 에이전트가 연결한 것도 포함)
    @Published private(set) var mounts: [MountTable.Entry] = []
    /// "지금 연결" 중인 서버
    @Published private(set) var mounting: Set<UUID> = []
    /// 서버별 마지막 "지금 연결" 결과
    @Published private(set) var results: [UUID: ServerResult] = [:]

    private var cancellables: Set<AnyCancellable> = []

    init() {
        refreshMountState()
        syncAutoConnectWithLoginItem()
        agent.connect()
        folders.start()
        // 동기화는 에이전트가 돌린다. 이 Mac 의 폴더 설정이 바뀌면 에이전트에 다시 읽으라고 알린다
        Publishers.CombineLatest(folders.$folders, folders.$local)
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in self?.syncFoldersChanged() }
            .store(in: &cancellables)
        SyncKeyStore.removeOldAppKey()
        ensureAgentAlive()

        let center = NSWorkspace.shared.notificationCenter
        Publishers.Merge(
            center.publisher(for: NSWorkspace.didMountNotification),
            center.publisher(for: NSWorkspace.didUnmountNotification)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.refreshMountState() }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                loginItem.refresh()
                syncAutoConnectWithLoginItem()
                refreshMountState()
                agent.connect()
                ensureAgentAlive()
            }
            .store(in: &cancellables)
    }

    private func syncFoldersChanged() {
        if folders.anyEnabled, !loginItem.isOn { setAutoConnect() }
        agent.syncCommand(.reloadFolders)
    }

    /// 앱이 뜨거나 앞으로 올 때: 에이전트가 있어야 하는데 이야기가 안 되면 다시 띄운다.
    /// (launchd 가 KeepAlive · MachServices 로 다시 띄우지만, 꺼져 있거나 멈춘 경우를 대비)
    /// 3초 뒤 한 번 더 묻고 그래도 10초 안에 답이 없을 때만: 큰 폴더를 다루느라 잠깐 늦게 답하는 에이전트를
    /// 강제로 끝내 주고받던 연결이 끊긴 적이 있다 (2026-11-29 맥북, 4초 만에 kickstart)
    private var checkingAgent = false
    func ensureAgentAlive() {
        guard !checkingAgent else { return }
        checkingAgent = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            if !agent.isConnected {
                agent.connect()
                try? await Task.sleep(for: .seconds(7))
            }
            checkingAgent = false
            guard !agent.isConnected else { return }
            let want = store.autoMountAtLogin || store.autoRemount || folders.anyEnabled
            guard want, LoginItemController.isDeveloperIDSigned() else { return }
            loginItem.refresh()
            if loginItem.status == .enabled {
                Log.app.info("에이전트와 이야기가 안 돼 다시 띄움 (launchctl kickstart)")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                p.arguments = ["kickstart", "-k", "gui/\(getuid())/\(AgentXPC.machServiceName)"]
                try? p.run()
                p.waitUntilExit()
            } else {
                Log.app.info("에이전트가 등록돼 있지 않아 다시 등록함")
                loginItem.setOn(true)
            }
            try? await Task.sleep(for: .seconds(2))
            agent.connect()
        }
    }

    func refreshMountState() {
        mounts = MountTable.smbMounts()
    }

    /// 이 공유가 붙어 있으면 그 자리
    func mountPoint(of share: String, on server: ServerConfig) -> String? {
        mounts.first { $0.matches(host: server.host, share: share) }?.mountPoint
    }

    /// 고른 공유 가운데 붙어 있는 수
    func mountedCount(_ server: ServerConfig) -> Int {
        server.shares.filter { mountPoint(of: $0, on: server) != nil }.count
    }

    /// 서버별 "지금 연결" — 한 번만 시도하고 결과를 그 서버 화면에 보여 준다.
    func mountNow(_ server: ServerConfig) {
        guard !mounting.contains(server.id) else { return }
        mounting.insert(server.id)
        results[server.id] = nil
        Task {
            let result = await Mounter.mount(server, attempts: 1, retryDelay: 0)
            results[server.id] = result
            mounting.remove(server.id)
            refreshMountState()
        }
    }

    // MARK: 자동 연결 (설정 > 서버)

    /// 두 자동 연결 가운데 하나라도 켜져 있으면 에이전트(로그인 항목)를 등록하고, 둘 다 꺼지면 해제한다.
    func setAutoConnect(atLogin: Bool? = nil, remount: Bool? = nil) {
        if let atLogin { store.autoMountAtLogin = atLogin }
        if let remount { store.autoRemount = remount }
        // 폴더 동기화를 켠 폴더가 있으면 에이전트는 늘 떠 있어야 한다
        let want = store.autoMountAtLogin || store.autoRemount || folders.anyEnabled
        if want != loginItem.isOn {
            loginItem.setOn(want)
        }
    }

    /// 로그인 항목이 등록되지 않았으면(처음 · 시스템 설정에서 끔) 두 토글도 꺼진 것으로 보여 준다.
    private func syncAutoConnectWithLoginItem() {
        guard loginItem.status == .notRegistered else { return }
        if store.autoMountAtLogin { store.autoMountAtLogin = false }
        if store.autoRemount { store.autoRemount = false }
    }
}
