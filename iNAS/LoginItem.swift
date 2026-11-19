import Foundation
import Security
import ServiceManagement

/// 앱 안의 LaunchAgent(`--mount-only`로 실행)를 SMAppService로 등록·해제한다.
@MainActor
final class LoginItemController: ObservableObject {
    static let plistName = "com.moimz.iNAS.agent.plist"

    private let service = SMAppService.agent(plistName: LoginItemController.plistName)
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published var lastError: String?

    init() { refresh() }

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
