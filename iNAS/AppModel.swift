import AppKit
import Combine
import Foundation

/// 자동 연결 대상 공유 하나의 현재 연결 상태
struct ShareState: Hashable, Identifiable {
    var serverName: String
    var share: String
    var mountPoint: String?
    var id: String { "\(serverName)/\(share)" }
}

@MainActor
final class AppModel: ObservableObject {
    let store = ServerStore()
    let loginItem = LoginItemController()

    @Published var isMounting = false
    @Published var lastResults: [ServerResult] = []
    @Published var lastRun: Date?
    /// 지금 실제로 연결되어 있는지 (로그인 항목이 연결한 것도 포함)
    @Published private(set) var shareStates: [ShareState] = []

    private var cancellables: Set<AnyCancellable> = []

    init() {
        refreshMountState()
        let center = NSWorkspace.shared.notificationCenter
        Publishers.Merge(
            center.publisher(for: NSWorkspace.didMountNotification),
            center.publisher(for: NSWorkspace.didUnmountNotification)
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.refreshMountState() }
        .store(in: &cancellables)

        store.$servers
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMountState() }
            .store(in: &cancellables)
    }

    func refreshMountState() {
        let mounts = MountTable.smbMounts()
        shareStates = store.servers.filter(\.enabled).flatMap { server in
            server.shares.map { share in
                ShareState(
                    serverName: server.displayName,
                    share: share,
                    mountPoint: mounts.first { $0.matches(host: server.host, share: share) }?.mountPoint
                )
            }
        }
    }

    /// "지금 연결" — 직접 실행했을 때는 한 번만 시도하고 결과를 창에 보여 준다.
    func mountNow() {
        guard !isMounting else { return }
        isMounting = true
        let servers = store.servers.filter { $0.enabled }
        Task {
            let results = await Mounter.mountAll(servers, attempts: 1, retryDelay: 0)
            lastResults = results
            lastRun = Date()
            isMounting = false
            refreshMountState()
        }
    }

    private var mountedCount: Int { shareStates.filter { $0.mountPoint != nil }.count }

    /// 창 아래에 보여 줄 현재 상태
    var summary: String {
        if shareStates.isEmpty { return "자동 연결할 공유가 없습니다." }
        let total = shareStates.count
        let mounted = mountedCount
        var text = mounted == total ? "공유 \(total)개 모두 연결됨" : "공유 \(total)개 중 \(mounted)개 연결됨"
        if lastRun != nil, lastResults.contains(where: { $0.state == .unreachable }) {
            text += " · 응답 없는 서버 있음"
        }
        return text
    }

    var hasProblems: Bool {
        mountedCount < shareStates.count
            || lastResults.contains { $0.state == .missingPassword || $0.failures > 0 }
    }
}
