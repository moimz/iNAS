import Foundation
import UserNotifications

enum Notifier {
    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// 아직 알림 권한을 물어본 적이 없을 때만 묻는다.
    /// 로그인 연결은 창 없이 돌기 때문에 거기서는 물을 수 없으므로, 설정 창이 열릴 때 미리 받아 둔다.
    static func requestAuthorizationIfNeeded() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        await requestAuthorization()
    }

    /// 로그인 연결 결과를 알린다. 새로 연결했거나 실패한 공유가 있을 때만 알림을 띄운다.
    /// 서버에 닿지 않은 경우는 조용히 넘어간다.
    static func postSummary(for results: [ServerResult]) async {
        let mounted = results.reduce(0) { $0 + $1.newlyMounted }
        let failed = results.reduce(0) { $0 + $1.failures }
        let noPassword = results.filter { $0.state == .missingPassword }.map(\.serverName)
        guard mounted > 0 || failed > 0 || !noPassword.isEmpty else { return }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        var lines: [String] = []
        if mounted > 0 { lines.append("공유 \(mounted)개를 연결했습니다.") }
        if failed > 0 { lines.append("공유 \(failed)개는 연결하지 못했습니다.") }
        if !noPassword.isEmpty { lines.append("비밀번호가 없는 서버: \(noPassword.joined(separator: ", "))") }

        let content = UNMutableNotificationContent()
        content.title = "iNAS"
        content.body = lines.joined(separator: "\n")
        content.sound = failed > 0 ? .defaultCritical : .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
        // 알림이 전달될 시간을 잠깐 준 뒤 종료한다.
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
}
