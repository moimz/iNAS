import Foundation
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
}
