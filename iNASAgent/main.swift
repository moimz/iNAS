import AppKit

// iNASAgent.app: 로그인 항목으로 늘 떠 있는 에이전트 + 메뉴 막대 아이콘.
// 번들 ID 가 본체와 달라(com.moimz.iNAS.agent) 본체로 가는 종료 요청 · open 과 섞이지 않는다.
// 우리가 등록한 상주 에이전트(launchd 라벨 com.moimz.iNAS.helper)로 뜬 것만 일한다.
// 옛 로그인 항목(com.moimz.iNAS.agent) 등 다른 길로 또 뜨면 둘이 같은 폴더를 동기화해 목록이 꼬이므로 바로 끝낸다 (2026-11-28 재부팅 뒤 둘이 뜸).
// launchd 밖에서 직접 띄운 것(XPC_SERVICE_NAME 없음 · 시험)은 막지 않는다.
if let label = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"], label != "0", label != AgentXPC.machServiceName {
    Log.app.error("에이전트가 \(label, privacy: .public) 로 떠서 끝냅니다 (상주 에이전트는 \(AgentXPC.machServiceName, privacy: .public) 하나만)")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    AgentService.shared.start()
    StatusMenu.shared.install()
}
app.run()

/// 메뉴 막대 아이콘의 메뉴: iNAS 열기 · iNAS 설정… · 서버 › (서버별) 지금 연결 · 마지막 기록
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()
    private var item: NSStatusItem?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: "iNAS")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "iNAS"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        self.item = item
    }

    /// 열 때마다 지금 서버 설정과 마운트로 다시 만든다.
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuild(menu) }
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = NSMenuItem(title: "iNAS 열기", action: #selector(openApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settings = NSMenuItem(title: "iNAS 설정…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let servers = ServerStore.loadServers()
        let mounts = MountTable.smbMounts()
        let busy = AgentService.shared.status.isRemounting
        let serverMenu = NSMenu()
        serverMenu.autoenablesItems = false
        if servers.isEmpty {
            serverMenu.addItem(disabled("등록된 서버가 없습니다"))
        }
        for server in servers {
            let total = server.shares.count
            let mounted = server.shares.filter { share in mounts.contains { $0.matches(host: server.host, share: share) } }.count
            let state: String
            if total == 0 {
                state = "고른 공유 없음"
            } else if mounted == total {
                state = "\(total)개 연결됨"
            } else {
                state = "\(total)개 중 \(mounted)개 연결됨"
            }
            let row = NSMenuItem(title: "\(server.displayName) 지금 연결 (\(state))", action: #selector(connect(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = server.id
            row.isEnabled = total > 0 && !server.host.isEmpty && !busy
            serverMenu.addItem(row)
        }
        let serversItem = NSMenuItem(title: busy ? "서버 (연결 중…)" : "서버", action: nil, keyEquivalent: "")
        serversItem.submenu = serverMenu
        menu.addItem(serversItem)

        if let last = AgentService.shared.status.events.first {
            menu.addItem(.separator())
            menu.addItem(disabled("\(Self.stamp(last.date)) \(last.text)"))
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func openApp() {
        NSWorkspace.shared.openApplication(at: AgentService.mainAppURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 본체 설정 창만 띄운다 (본체가 inas://settings 를 받아 처리)
    @objc private func openSettings() {
        guard let url = URL(string: "inas://settings") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: AgentService.mainAppURL, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func connect(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        AgentService.shared.connectNow(id)
    }

    /// 오늘이면 시각만, 아니면 날짜와 시각
    private static func stamp(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}
