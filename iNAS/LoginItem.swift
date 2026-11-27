import Foundation
import Security
import ServiceManagement

/// 앱 안의 LaunchAgent(iNASAgent.app, 메뉴 막대 에이전트)를 SMAppService로 등록·해제한다.
@MainActor
final class LoginItemController: ObservableObject {
    static let plistName = "com.moimz.iNAS.helper.plist"
    /// 빌드 50까지의 이름. 같은 이름으로 다시 등록하면 BTM 항목을 다시 써서 실행 조건(LWCR)이
    /// 본체 서명 ID(com.moimz.iNAS) 그대로 남아 iNASAgent(com.moimz.iNAS.agent)가 EX_CONFIG 로 못 떴다(2026-11-27).
    /// 그래서 이름을 바꿔 새 항목으로 등록하고, 옛 것은 한 번 해제한다.
    private static let legacyPlistName = "com.moimz.iNAS.agent.plist"

    private let service = SMAppService.agent(plistName: LoginItemController.plistName)
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published var lastError: String?

    /// 마지막으로 등록할 때의 에이전트 plist 내용
    private static let registeredPlistKey = "agentPlistAtRegister"

    init() {
        refresh()
        migrateFromLegacyAgent()
        reregisterIfPlistChanged()
    }

    /// 옛 로그인 항목(com.moimz.iNAS.agent)이 켜져 있으면 해제하고 새 항목을 등록한다.
    private func migrateFromLegacyAgent() {
        let legacy = SMAppService.agent(plistName: Self.legacyPlistName)
        // 해제하려면 앱 안에 옛 plist 가 있어야 해서 Support/com.moimz.iNAS.agent.plist(한 번 돌고 끝나는 --mount-only)를 남겨 둔다.
        guard legacy.status == .enabled || legacy.status == .requiresApproval else { return }
        do {
            try legacy.unregister()
            Log.app.info("옛 로그인 항목(com.moimz.iNAS.agent)을 해제함")
        } catch {
            Log.app.error("옛 로그인 항목 해제 실패: \(error.localizedDescription)")
        }
        guard status != .enabled, Self.isDeveloperIDSigned() else { return }
        do {
            try service.register()
            Prefs.defaults.set(Self.bundledPlist(), forKey: Self.registeredPlistKey)
            Log.app.info("새 로그인 항목(com.moimz.iNAS.helper)을 등록함")
        } catch {
            lastError = error.localizedDescription
            Log.app.error("새 로그인 항목 등록 실패: \(error.localizedDescription)")
        }
        refresh()
    }

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    var statusText: String? {
        switch status {
        case .requiresApproval: return "시스템 설정 › 일반 › 로그인 항목에서 iNAS를 허용해야 합니다."
        case .notFound: return "앱 안의 로그인 항목 정보를 찾지 못했습니다."
        default: return nil
        }
    }

    func refresh() {
        status = service.status
    }

    func setOn(_ on: Bool) {
        lastError = nil
        do {
            if on {
                // 개발 빌드(Apple Development)로 등록하면 에이전트의 실행 조건(LWCR)이 개발 빌드 기준으로 굳어,
                // Developer ID 로 설치한 앱의 에이전트가 Launch Constraint Violation 으로 죽는다(되돌리려면 sfltool resetbtm).
                // 그래서 Developer ID 로 서명된 앱에서만 등록한다. 해제는 막지 않는다.
                guard Self.isDeveloperIDSigned() else {
                    lastError = "개발 빌드에서는 로그인 항목을 등록하지 않습니다. Developer ID 로 설치한 앱에서 켜 주세요."
                    Log.app.error("개발 빌드라 로그인 항목 등록을 건너뜀")
                    refresh()
                    return
                }
                try service.register()
                Prefs.defaults.set(Self.bundledPlist(), forKey: Self.registeredPlistKey)
            } else {
                try service.unregister()
            }
        } catch {
            lastError = error.localizedDescription
            Log.app.error("로그인 항목 변경 실패: \(error.localizedDescription)")
        }
        refresh()
        if on, status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// 앱 안의 에이전트 plist 가 등록할 때와 달라졌으면 다시 등록한다.
    /// launchd 는 등록할 때 읽은 plist 를 들고 있어서(`launchctl print` 의 arguments), 앱만 바꿔서는
    /// 새 설정(예: 한 번 돌고 끝나던 `--mount-only` → 늘 떠 있는 `--agent`)이 먹지 않는다.
    /// 등록과 같은 이유로 Developer ID 로 서명된 앱에서만 한다.
    func reregisterIfPlistChanged() {
        guard status == .enabled, Self.isDeveloperIDSigned(), let current = Self.bundledPlist(),
              Prefs.defaults.data(forKey: Self.registeredPlistKey) != current
        else { return }
        do {
            try service.unregister()
            try service.register()
            Prefs.defaults.set(current, forKey: Self.registeredPlistKey)
            Log.app.info("에이전트 plist 가 바뀌어 로그인 항목을 다시 등록함")
        } catch {
            lastError = error.localizedDescription
            Log.app.error("로그인 항목 다시 등록 실패: \(error.localizedDescription)")
        }
        refresh()
    }

    private static func bundledPlist() -> Data? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)")
        return try? Data(contentsOf: url)
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// 지금 실행 중인 앱이 우리 팀의 Developer ID 로 서명됐는지
    nonisolated static func isDeveloperIDSigned() -> Bool {
        let text = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"XSDBV8D2XL\""
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
