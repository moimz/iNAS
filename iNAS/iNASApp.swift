import AppKit
import SwiftUI

/// 실행 인자에 따라 두 가지로 동작한다.
/// - `--mount-only`: 창 없이 연결만 하고 종료한다. 에이전트(iNASAgent.app)가 연결할 때 띄운다(옛 로그인 항목도 이것으로 실행).
/// - 그 외: 사용자가 직접 실행한 경우. 설정 창을 띄운다.
/// 늘 떠 있는 에이전트와 메뉴 막대는 앱 안의 iNASAgent.app 이다.
@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains(HeadlessRunner.argument) {
            HeadlessRunner.run()
        } else if CommandLine.arguments.contains(SyncDiscovery.schemaArgument) {
            SyncDiscovery.runSchemaSeed()
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
                .environmentObject(model.folders)
                .environmentObject(model.loginItem)
                .environmentObject(model.agent)
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
        // 메뉴 막대에서 inas:// 로 부를 때 SwiftUI 가 이 창(장면)에 넘기며 다시 띄워 메인 창이 깜빡였다(사용자 2026-11-28, iRayer 와 같은 일).
        // 주소는 AppDelegate.application(_:open:) 가 받으므로 장면은 받지 않는다 → 주소로 켜지면 메인 창을 아예 안 만든다
        .handlesExternalEvents(matching: [])
        .commands {
            DetailWindowOpener()
            // iNAS에 관하여: 기본 정보 창 그대로, 버전 줄만 Ai.md 모양 "2.3.1 (빌드 45 · 1231858)" (사용자 2026-11-26, iVNC 와 같게)
            CommandGroup(replacing: .appInfo) {
                Button("iNAS에 관하여") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationVersion: AppVersion.text,
                        .version: "",
                    ])
                    NSApp.activate(ignoringOtherApps: true)
                }
                UpdateMenuButton()
            }
            CommandGroup(replacing: .newItem) {}
            // 도움말: 저장소 · 문제 신고 (Ai.md "도움말 메뉴", 도움말 책이 없어 기본 "iNAS 도움말" 은 뺀다)
            CommandGroup(replacing: .help) {
                Button("iNAS GitHub 페이지") { NSWorkspace.shared.open(URL(string: "https://github.com/moimz/iNAS")!) }
                Button("문제 신고…") { NSWorkspace.shared.open(Self.issueURL) }
            }
        }

        // 폴더 상세 (탐색 · 받기 · 보내기): 폴더마다 창 하나
        WindowGroup("폴더 상세", id: "folderDetail", for: FolderDetailTarget.self) { $target in
            if let target {
                FolderDetailView(target: target)
                    .environmentObject(model.folders)
                    .environmentObject(model.agent)
            }
        }
        .defaultSize(width: 860, height: 560)
        .handlesExternalEvents(matching: [])
        .commandsRemoved()

        // iNAS 설정 (⌘,): 일반(업데이트) · 서버(자동 연결) · 동기화(기기) · 기록(서버 · 동기화)
        Settings {
            AppSettingsView()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.loginItem)
                .environmentObject(model.agent)
        }
    }
}

extension INASApp {
    /// 새 이슈 화면, 본문에 앱 · macOS 버전만 미리 채운다 (개인 정보는 넣지 않는다)
    static var issueURL: URL {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var c = URLComponents(string: "https://github.com/moimz/iNAS/issues/new")!
        c.queryItems = [URLQueryItem(name: "body", value: "\n\n---\niNAS \(AppVersion.text) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")]
        return c.url!
    }
}

/// 메뉴 막대에서 온 "이 폴더 상세 창을 열어 달라". 창을 여는 openWindow 는 뷰에만 있어서 메인 창(ContentView)이 받아 연다.
/// 막 켜진 앱이면 뷰가 아직 없으니 pending 에 두고 뷰가 나타날 때 가져간다
/// 상세 창을 여는 openWindow 를 메뉴(Commands) 쪽에서 잡아 둔다. 주소로 켜지면 메인 창이 없어 뷰에서는 못 연다(iRayer MacCommands 와 같은 방식)
struct DetailWindowOpener: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = { [openWindow] in FolderDetailRequest.opener = { openWindow(id: "folderDetail", value: $0) } }()
        CommandGroup(after: .windowArrangement) {}
    }
}

@MainActor
enum FolderDetailRequest {
    /// DetailWindowOpener 가 넣어 둠
    static var opener: ((FolderDetailTarget) -> Void)?
    static let notification = Notification.Name("iNAS.openFolderDetail")
    private(set) static var pending: (target: FolderDetailTarget, tab: Int)?

    static func post(_ target: FolderDetailTarget, tab: Int) {
        if let opener {
            // 이미 열린 창이면 그 창이 이 요청을 받아 탭을 바꾼다
            UserDefaults.standard.set(target.key + "#\(tab)", forKey: FolderDetailView.tabRequestKey)
            opener(target)
            return
        }
        pending = (target, tab)
        NotificationCenter.default.post(name: notification, object: nil)
    }

    static func take() -> (target: FolderDetailTarget, tab: Int)? {
        defer { pending = nil }
        return pending
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// `inas://settings` — 메뉴 막대(iNASAgent)의 "iNAS 설정…". 설정 창만 띄운다.
    /// `inas://detail/<폴더 아이디>?tab=N[&peer=<키 아이디>]` — 메뉴 막대 폴더의 기기 줄 · "충돌 사본 관리…". 그 폴더(그 기기) 상세 창을 연다.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first(where: { $0.scheme == "inas" && $0.host == "detail" }),
           let id = url.pathComponents.dropFirst().first {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let tab = items.first { $0.name == "tab" }?.value.flatMap(Int.init) ?? 0
            let peer = items.first { $0.name == "peer" }?.value.flatMap { $0.isEmpty ? nil : $0 }
            FolderDetailRequest.post(FolderDetailTarget(folderID: id, peer: peer), tab: tab)
            NSApp.activate()
            return
        }
        guard urls.contains(where: { $0.scheme == "inas" && $0.host == "settings" }) else { return }
        // 메인 창은 주소를 받지 않으므로(handlesExternalEvents) 주소로 켜져도 메인 창이 안 생긴다. 예전엔 생긴 메인 창을 0.6초 뒤 닫아 깜빡였다
        DispatchQueue.main.async { Self.openSettings() }
    }

    /// SwiftUI 가 만든 앱 메뉴의 "설정…"(⌘,)을 그대로 누른다.
    /// (macOS 14 부터 showSettingsWindow: 를 직접 보내는 길은 막혔고, openSettings 는 뷰 안에서만 쓸 수 있다)
    static func openSettings() {
        NSApp.activate()
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: {
                  $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command)
              })
        else {
            Log.app.error("앱 메뉴에서 설정… 항목을 찾지 못함")
            return
        }
        appMenu.performActionForItem(at: index)
    }
}

/// 로그인 시 실행되는 창 없는 모드.
enum HeadlessRunner {
    static let argument = MountCommand.argument
    static let serversArgument = MountCommand.serversArgument
    static let reportArgument = MountCommand.reportArgument

    static func run() -> Never {
        // Dock 아이콘이나 메뉴 막대가 나타나지 않게 한다.
        NSApplication.shared.setActivationPolicy(.prohibited)

        // 어떤 이유로든 멈추면 3분 뒤 강제로 끝낸다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            Log.app.error("시간 초과로 종료합니다.")
            exit(1)
        }

        Task.detached {
            var servers = ServerStore.loadServers().filter { $0.enabled }
            if let only = Self.serverFilter() {
                servers = servers.filter { only.contains($0.id) }
            }
            Log.app.info("로그인 연결 시작: 서버 \(servers.count)개")
            // 로그인 직후에는 네트워크가 늦게 잡힐 수 있으므로 몇 번 다시 시도한다.
            let results = await Mounter.mountAll(servers, attempts: 6, retryDelay: 5)
            if ServerStore.loadNotifyPreference() {
                await Notifier.postSummary(for: results)
            }
            if CommandLine.arguments.contains(Self.reportArgument),
               let data = try? JSONEncoder().encode(results) {
                FileHandle.standardOutput.write(data + Data("\n".utf8))
            }
            Log.app.info("로그인 연결 끝")
            exit(0)
        }
        dispatchMain()
    }

    private static func serverFilter() -> Set<UUID>? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: serversArgument), i + 1 < args.count else { return nil }
        return Set(args[i + 1].split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }
}
