import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let store = ServerStore()
    let loginItem = LoginItemController()
    /// 상주 에이전트(자동 연결) 상태와 기록
    let agent = AgentClient()

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
            }
            .store(in: &cancellables)
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
        let want = store.autoMountAtLogin || store.autoRemount
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
