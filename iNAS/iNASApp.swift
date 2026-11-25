import AppKit
import SwiftUI

/// 실행 인자에 따라 두 가지로 동작한다.
/// - `--mount-only`: 로그인 항목(LaunchAgent)으로 실행된 경우. 창 없이 연결만 하고 종료한다.
/// - 그 외: 사용자가 직접 실행한 경우. 설정 창을 띄운다.
@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains(HeadlessRunner.argument) {
            HeadlessRunner.run()
        } else {
            INASApp.main()
        }
    }
}

struct INASApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() {
        // 자동 업데이트: 켜 두었으면 하루 한 번 새 버전을 확인한다
        _ = Updater.shared
    }

    var body: some Scene {
        Window("iNAS", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.loginItem)
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // iNAS에 관하여: 기본 정보 창 대신 직접 만든 창 (AboutView, iSQL 과 같은 모양), 그 아래 업데이트 확인
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
                UpdateMenuButton()
            }
            CommandGroup(replacing: .newItem) {}
        }

        // iNAS 정보 창
        Window("iNAS 정보", id: AboutView.windowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)

        // iNAS 설정 (⌘,): 업데이트
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// 로그인 시 실행되는 창 없는 모드.
enum HeadlessRunner {
    static let argument = "--mount-only"

    static func run() -> Never {
        // Dock 아이콘이나 메뉴 막대가 나타나지 않게 한다.
        NSApplication.shared.setActivationPolicy(.prohibited)

        // 어떤 이유로든 멈추면 3분 뒤 강제로 끝낸다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            Log.app.error("시간 초과로 종료합니다.")
            exit(1)
        }

        Task.detached {
            let servers = ServerStore.loadServers().filter { $0.enabled }
            Log.app.info("로그인 연결 시작: 서버 \(servers.count)개")
            // 로그인 직후에는 네트워크가 늦게 잡힐 수 있으므로 몇 번 다시 시도한다.
            let results = await Mounter.mountAll(servers, attempts: 6, retryDelay: 5)
            if ServerStore.loadNotifyPreference() {
                await Notifier.postSummary(for: results)
            }
            Log.app.info("로그인 연결 끝")
            exit(0)
        }
        dispatchMain()
    }
}
