import Foundation

// MARK: XPC 약속 (에이전트 ↔ 앱 창)

/// 상주 에이전트와 앱 창이 주고받는 XPC 이름과 상대 서명 조건
enum AgentXPC {
    /// 에이전트 plist(com.moimz.iNAS.helper.plist)의 Label · MachServices 이름과 같아야 한다.
    static let machServiceName = "com.moimz.iNAS.helper"
    /// 우리 팀(XSDBV8D2XL)이 서명한 상대만 받는다. 개발 빌드(Apple Development)와 Developer ID 모두 통과한다.
    /// 에이전트는 앱(com.moimz.iNAS)만, 앱은 에이전트(com.moimz.iNAS.agent)만 상대한다.
    static let appRequirement = requirement("com.moimz.iNAS")
    static let agentRequirement = requirement("com.moimz.iNAS.agent")

    private static func requirement(_ identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"XSDBV8D2XL\""
    }

    static func agentInterface() -> NSXPCInterface { NSXPCInterface(with: INASAgentProtocol.self) }
    static func clientInterface() -> NSXPCInterface { NSXPCInterface(with: INASAgentClientProtocol.self) }
}

/// 앱 → 에이전트. 상태는 AgentStatus 를 JSON 으로 담아 주고받는다.
@objc protocol INASAgentProtocol {
    func fetchStatus(reply: @escaping (Data) -> Void)
    /// 앱이 새 버전으로 바뀌었을 때 옛 에이전트를 끝낸다. launchd(KeepAlive)가 새 실행 파일로 다시 띄운다.
    func restart()
    /// 동기화 상태 (SyncSnapshot JSON)
    func fetchSync(reply: @escaping (Data) -> Void)
    /// 동기화 명령 (SyncCommand JSON)
    func syncCommand(_ data: Data)
}

/// 에이전트 → 앱 창. 상태가 바뀔 때마다 보낸다.
@objc protocol INASAgentClientProtocol {
    func statusDidChange(_ data: Data)
    /// 동기화 상태가 바뀜 (SyncSnapshot JSON, 0.5초에 한 번까지)
    func syncDidChange(_ data: Data)
}

/// 설정 > 서버 아래에 보여 줄 기록 한 줄
struct AgentEvent: Codable, Equatable, Identifiable {
    enum Level: String, Codable { case info, ok, warn }
    var id = UUID()
    var date: Date
    var level: Level
    var text: String
}

/// 에이전트만 아는 상태
struct AgentStatus: Codable, Equatable {
    var build: String
    /// 에이전트가 들어 있는 iNAS.app 자리 (앱이 같은 자리의 앱인지 볼 때 쓴다)
    var bundlePath: String
    var startedAt: Date
    var isRemounting = false
    /// 최근 기록 (새것이 앞)
    var events: [AgentEvent] = []

    static func decode(_ data: Data) -> AgentStatus? {
        try? JSONDecoder().decode(AgentStatus.self, from: data)
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}

/// 연결만 하고 끝나는 모드(`iNAS --mount-only`)의 인자. 에이전트가 이걸로 본체를 띄워 연결한다.
enum MountCommand {
    static let argument = "--mount-only"
    /// 이 서버들만 연결한다: `--servers id,id`
    static let serversArgument = "--servers"
    /// 결과를 표준 출력 마지막 줄에 JSON 으로 남긴다 (에이전트가 읽음)
    static let reportArgument = "--report"
}
