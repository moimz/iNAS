import Foundation

/// 앱 쪽 XPC 손님. 상주 에이전트의 상태(자동 연결 기록)를 받아 설정 > 서버 에 보여 준다.
/// 마운트돼 있는지는 창이 직접 본다(AppModel). 여기서는 에이전트만 아는 것만 받는다.
@MainActor
final class AgentClient: ObservableObject {
    @Published private(set) var status: AgentStatus?
    /// 에이전트와 이야기가 되는지. 로그인 항목이 꺼져 있거나 아직 옛 에이전트면 false.
    @Published private(set) var isConnected = false
    /// 에이전트가 돌리는 동기화의 상태 (설정 > 동기화 · 폴더 화면)
    @Published private(set) var sync: SyncSnapshot?

    private var connection: NSXPCConnection?
    private var askedRestart = false

    /// 창이 열리거나 앞으로 올 때 부른다. 연결이 없으면 새로 맺고, 있으면 상태만 다시 받는다.
    func connect() {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: AgentXPC.machServiceName, options: [])
            c.setCodeSigningRequirement(AgentXPC.agentRequirement)
            c.remoteObjectInterface = AgentXPC.agentInterface()
            c.exportedInterface = AgentXPC.clientInterface()
            c.exportedObject = ClientExport()
            // 에이전트가 다시 떴다(업데이트 등). 연결은 그대로 쓸 수 있으니 잠깐 뒤 다시 받아 알림 대상으로 다시 등록한다.
            c.interruptionHandler = {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    MainActor.assumeIsolated { AgentClient.shared?.refresh() }
                }
            }
            c.invalidationHandler = {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        AgentClient.shared?.connection = nil
                        AgentClient.shared?.isConnected = false
                        AgentClient.shared?.status = nil
                    }
                }
            }
            c.resume()
            connection = c
            Self.shared = self
        }
        refresh()
    }

    func refresh() {
        proxy()?.fetchStatus { data in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AgentClient.shared?.apply(data) }
            }
        }
        proxy()?.fetchSync { data in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AgentClient.shared?.applySync(data) }
            }
        }
    }

    func syncCommand(_ c: SyncCommand) {
        proxy()?.syncCommand(c.encoded())
    }

    /// 폴더 상세 창 정보 (창이 열려 있는 동안 1초마다). peer 가 있으면 그 Mac 에 달라고 해서 (연결 없으면 nil)
    func folderDetail(_ folderID: String, peer: String? = nil) async -> SyncFolderDetail? {
        guard let p = proxy() else { return nil }
        return await withCheckedContinuation { cont in
            let once = Once()
            p.fetchFolderDetail(folderID, peer: peer ?? "") { data in once.run { cont.resume(returning: SyncFolderDetail.decode(data)) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { once.run { cont.resume(returning: nil) } }
        }
    }

    fileprivate func applySync(_ data: Data) {
        guard let s = SyncSnapshot.decode(data), s != sync else { return }
        sync = s
    }

    /// 앱이 한 개라 손님도 하나. XPC 콜백에서 찾아가려고 둔다.
    fileprivate static weak var shared: AgentClient?

    private func proxy() -> INASAgentProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AgentClient.shared?.isConnected = false }
            }
        } as? INASAgentProtocol
    }

    fileprivate func apply(_ data: Data) {
        guard let s = AgentStatus.decode(data) else { return }
        status = s
        isConnected = true
        restartIfOld(s)
    }

    /// 업데이트로 앱이 바뀌었는데 에이전트가 옛 빌드로 떠 있으면 끝내게 한다(launchd 가 새로 띄움).
    /// 같은 자리의 앱일 때만 한다. Xcode 개발 빌드가 설치본 에이전트를 건드리지 않게.
    private func restartIfOld(_ s: AgentStatus) {
        let mine = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        guard !askedRestart, s.bundlePath == Bundle.main.bundlePath, let mine, s.build != mine else { return }
        askedRestart = true
        proxy()?.restart()
    }
}

/// 에이전트가 보내 주는 상태를 받는다.
private final class ClientExport: NSObject, INASAgentClientProtocol {
    func statusDidChange(_ data: Data) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AgentClient.shared?.apply(data) }
        }
    }

    func syncDidChange(_ data: Data) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AgentClient.shared?.applySync(data) }
        }
    }
}

extension Date {
    /// 오늘이면 시각만, 아니면 날짜와 시각
    var shortStamp: String {
        Calendar.current.isDateInToday(self)
            ? formatted(date: .omitted, time: .shortened)
            : formatted(date: .abbreviated, time: .shortened)
    }
}
