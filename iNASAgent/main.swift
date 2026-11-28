import AppKit
import Combine

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

/// 메뉴 막대 아이콘의 메뉴: iNAS 열기 · iNAS 설정… · 폴더(폴더마다 줄) · 서버(서버마다 줄). 줄 왼쪽에 상태 아이콘(점 · sync, 같은 칸)
/// 아이콘: 주고받는 중이면 오른쪽 위에 점 하나 (사용자 2026-11-28)
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    static let shared = StatusMenu()
    private var item: NSStatusItem?
    private var watch: AnyCancellable?
    private var showingDot: Bool?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.toolTip = "iNAS"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        self.item = item
        setIcon(active: false)
        watch = AgentService.shared.sync.$folderStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] st in
                MainActor.assumeIsolated { self?.setIcon(active: Self.transferring(st)) }
            }
    }

    /// 받는 중 · 보내는 중 (훑기만 할 때는 점을 안 찍는다 — 한 시간마다 재탐색에 깜빡이지 않게)
    private static func transferring(_ st: [String: SyncFolderStatus]) -> Bool {
        st.values.contains { $0.state == .syncing || $0.needItems > 0 || $0.peerNeed.values.contains { $0 > 0 } }
    }

    private func setIcon(active: Bool) {
        guard showingDot != active else { return }
        showingDot = active
        item?.button?.image = Self.icon(dot: active)
        item?.button?.toolTip = active ? "iNAS — 동기화 중" : "iNAS"
    }

    /// 서버 아이콘 + (주고받는 중이면) 오른쪽 위 점. 점 둘레는 비워서 아이콘과 붙어 보이지 않게
    private static func icon(dot: Bool) -> NSImage? {
        guard let base = NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: "iNAS")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) else { return nil }
        guard dot else {
            base.isTemplate = true
            return base
        }
        let pad: CGFloat = 3
        let size = NSSize(width: base.size.width + pad, height: base.size.height + pad)
        let image = NSImage(size: size, flipped: false) { r in
            base.draw(in: NSRect(x: 0, y: 0, width: base.size.width, height: base.size.height))
            let d: CGFloat = 6.5, ring: CGFloat = 1.5
            let dotRect = NSRect(x: r.width - d, y: r.height - d, width: d, height: d)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -ring, dy: -ring)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 열 때마다 지금 상태로 다시 만든다.
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

        addFolders(menu)
        addServers(menu)
    }

    // MARK: 상태 표시 (사용자 2026-11-28: 글 대신 오른쪽 끝 아이콘 하나)

    enum Mark {
        /// 맞춰짐 · 다 연결됨
        case ok
        /// 상대가 오프라인 · 연결 안 됨
        case offline
        /// 이 Mac 은 안 함 (꺼짐 · 준비 중 · 고른 공유 없음)
        case off
        /// 동기화 중 · 연결 중
        case busy
        /// 문제 (멈춤 · 충돌 사본 · 일부만 연결)
        case problem

        /// 줄 왼쪽 아이콘. 점이든 sync 아이콘이든 같은 칸(16×16) 가운데에 그려 이름이 한 줄로 맞게
        var image: NSImage? {
            let inner: NSImage?
            switch self {
            case .ok: inner = Self.dot(.systemGreen)
            case .offline: inner = Self.dot(.systemRed)
            case .off: inner = Self.dot(.systemGray)
            case .busy: inner = Self.symbol("arrow.triangle.2.circlepath", .systemBlue)
            case .problem: inner = Self.symbol("exclamationmark.arrow.triangle.2.circlepath", .systemOrange)
            }
            guard let inner else { return nil }
            return Self.boxed(inner)
        }

        /// 16×16 칸 가운데에 미리 그려 둔 비트맵 (그리기 핸들러로 된 이미지는 메뉴에서 안 그려져 점이 사라졌다, 빌드 102)
        private static func boxed(_ inner: NSImage) -> NSImage? {
            let pt: CGFloat = 16, scale: CGFloat = 2
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pt * scale), pixelsHigh: Int(pt * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = NSSize(width: pt, height: pt)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let s = inner.size
            inner.draw(in: NSRect(x: (pt - s.width) / 2, y: (pt - s.height) / 2, width: s.width, height: s.height))
            NSGraphicsContext.restoreGraphicsState()
            let image = NSImage(size: NSSize(width: pt, height: pt))
            image.addRepresentation(rep)
            return image
        }

        private static func dot(_ c: NSColor) -> NSImage? {
            NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .regular).applying(.init(paletteColors: [c])))
        }

        private static func symbol(_ name: String, _ c: NSColor) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium).applying(.init(paletteColors: [c])))
        }
    }

    // MARK: 폴더

    private func addFolders(_ menu: NSMenu) {
        let store = AgentService.shared.folders
        guard !store.folders.isEmpty else { return }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "폴더"))
        let snap = AgentService.shared.sync.snapshot()
        for f in store.folders {
            let st = snap.folderStatus[f.id]
            let state = folderState(f.id, st)
            let row = NSMenuItem(title: f.name, action: nil, keyEquivalent: "")
            row.image = state.mark.image
            row.submenu = folderMenu(f, st, snap, state.text)
            menu.addItem(row)
        }
    }

    /// 이 Mac 에서 본 폴더 상태 (앱 폴더 화면 "상태" 줄과 같은 판단)
    private func folderState(_ id: String, _ st: SyncFolderStatus?) -> (text: String, mark: Mark) {
        let store = AgentService.shared.folders
        let s = store.setting(id)
        guard s.enabled, s.path != nil else { return ("이 Mac 에서 꺼짐", .off) }
        guard let st else { return ("준비 중", .off) }
        if st.state == .stopped || st.lastError != nil { return ("멈춤" + (st.lastError.map { " — \($0)" } ?? ""), .problem) }
        if st.state == .syncing || st.needItems > 0 {
            return (st.needItems > 0 ? "받는 중 \(st.needItems.formatted())개" : "맞추는 중", .busy)
        }
        let sending = st.peerNeed.values.reduce(0, +)
        if sending > 0 { return ("보내는 중 \(sending.formatted())개", .busy) }
        if st.state == .scanning { return ("훑는 중", .busy) }
        if !st.conflicts.isEmpty { return ("충돌 사본 \(st.conflicts.count.formatted())개", .problem) }
        if st.peerNeed.isEmpty { return ("다른 Mac 과 연결 안 됨", .offline) }
        return ("맞춰짐", .ok)
    }

    private func folderMenu(_ f: SyncFolder, _ st: SyncFolderStatus?, _ snap: SyncSnapshot, _ stateText: String) -> NSMenu {
        let store = AgentService.shared.folders
        let s = store.setting(f.id)
        let on = s.enabled && s.path != nil
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(NSMenuItem.sectionHeader(title: stateText))

        let detail = NSMenuItem(title: "상세보기…", action: #selector(openDetail(_:)), keyEquivalent: "")
        detail.target = self
        detail.representedObject = "\(f.id)?tab=0"
        m.addItem(detail)
        if let n = st?.conflicts.count, n > 0, on {
            let c = NSMenuItem(title: "충돌 사본 \(n.formatted())개 관리…", action: #selector(openDetail(_:)), keyEquivalent: "")
            c.target = self
            c.representedObject = "\(f.id)?tab=3"
            c.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
            m.addItem(c)
        }
        if on, let path = store.resolvedPath(f.id) {
            let finder = NSMenuItem(title: "Finder 에서 열기", action: #selector(revealFolder(_:)), keyEquivalent: "")
            finder.target = self
            finder.representedObject = path
            m.addItem(finder)
            let rescan = NSMenuItem(title: "지금 재탐색", action: #selector(rescan(_:)), keyEquivalent: "")
            rescan.target = self
            rescan.representedObject = f.id
            rescan.isEnabled = st?.state != .scanning
            m.addItem(rescan)
        }

        // 이 폴더를 쓰는 기기: 이 Mac · 다른 Mac 마다 한 줄 (보기만)
        m.addItem(.separator())
        let me = on ? (st.map { "\($0.localFiles.formatted())개 · \(Self.size($0.localBytes))" } ?? "준비 중") : "꺼짐"
        m.addItem(pair(snap.me.name, me, mark: on ? (st == nil ? .off : .ok) : .off))
        for p in snap.peers where p.blockedKey == nil {
            let uses = p.device.folders[f.id] != nil || (p.keyID.map { st?.peerNeed[$0] != nil } ?? false)
            guard uses else { continue }
            let text: String
            let mark: Mark
            if let k = p.keyID, let need = st?.peerNeed[k] {
                if need > 0 {
                    (text, mark) = ("받는 중 \(need.formatted())개", .busy)
                } else if let n = st?.peerFiles[k] {
                    (text, mark) = ("맞춰짐 · \(n.formatted())개", .ok)
                } else {
                    (text, mark) = ("연결됨", .busy)
                }
            } else {
                let last = p.device.folders[f.id]?.lastSync.map { " · 마지막 동기화 \(Self.stamp($0))" } ?? ""
                (text, mark) = ("연결 안 됨" + last, .offline)
            }
            m.addItem(pair(p.device.name, text, mark: mark))
        }
        tightenPairs(m)
        return m
    }

    // MARK: 서버

    /// "서버" 머리글 + 서버마다 한 줄(오른쪽 끝 표시) · 하위 메뉴(지금 연결 · 공유폴더마다 한 줄)
    private func addServers(_ menu: NSMenu) {
        let servers = ServerStore.loadServers()
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "서버"))
        guard !servers.isEmpty else {
            menu.addItem(info("등록된 서버가 없습니다"))
            return
        }
        let mounts = MountTable.smbMounts()
        let busy = AgentService.shared.status.isRemounting
        for server in servers {
            let shares = server.shares.map { share in (share, mounts.first { $0.matches(host: server.host, share: share) }) }
            let total = shares.count
            let mounted = shares.filter { $0.1 != nil }.count
            let text: String
            let mark: Mark
            if busy {
                (text, mark) = ("연결 중…", .busy)
            } else if total == 0 {
                (text, mark) = ("고른 공유폴더 없음", .off)
            } else if mounted == total {
                (text, mark) = ("공유폴더 \(total)개 연결됨", .ok)
            } else if mounted == 0 {
                (text, mark) = ("연결 안 됨", .offline)
            } else {
                (text, mark) = ("공유폴더 \(total)개 중 \(mounted)개 연결됨", .problem)
            }
            let row = NSMenuItem(title: server.displayName, action: nil, keyEquivalent: "")
            row.image = mark.image

            let sub = NSMenu()
            sub.autoenablesItems = false
            sub.addItem(NSMenuItem.sectionHeader(title: text))
            let connect = NSMenuItem(title: "지금 연결", action: #selector(connect(_:)), keyEquivalent: "")
            connect.target = self
            connect.representedObject = server.id
            connect.isEnabled = total > 0 && !server.host.isEmpty && !busy && mounted < total
            sub.addItem(connect)
            if !shares.isEmpty { sub.addItem(.separator()) }
            // 공유폴더마다 한 줄: 연결됐으면 누르면 Finder 로
            for (share, mount) in shares {
                let item = NSMenuItem(title: share, action: mount == nil ? nil : #selector(revealFolder(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = mount?.mountPoint
                item.isEnabled = mount != nil
                item.image = (mount == nil ? Mark.offline : Mark.ok).image
                sub.addItem(item)
            }
            row.submenu = sub
            menu.addItem(row)
        }
    }

    // MARK: 줄 모양

    /// 보기만 하는 줄: 왼쪽 이름 · 오른쪽 끝에 맞춘 자세한 글 (사용자 2026-11-28)
    private func pair(_ name: String, _ detail: String, mark: Mark?) -> NSMenuItem {
        let item = info(name, mark: mark)
        let font = NSFont.menuFont(ofSize: 0)
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: 300)]  // tightenPairs 가 메뉴마다 줄인다
        let t = NSMutableAttributedString(string: name + "\t", attributes: [
            .font: font, .paragraphStyle: para, .foregroundColor: NSColor.labelColor,
        ])
        t.append(NSAttributedString(string: detail, attributes: [
            .font: font, .paragraphStyle: para, .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        item.attributedTitle = t
        return item
    }

    /// 한 메뉴 안 "이름 ⇥ 자세한 글" 줄들의 오른쪽 탭을 가장 긴 이름 + 간격 + 가장 긴 글 로 맞춘다 (빈칸이 너무 넓지 않게)
    private func tightenPairs(_ m: NSMenu) {
        let rows = m.items.compactMap { item -> (NSMenuItem, NSAttributedString)? in
            guard let t = item.attributedTitle, t.string.contains("\t") else { return nil }
            return (item, t)
        }
        guard !rows.isEmpty else { return }
        let font = NSFont.menuFont(ofSize: 0)
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        var nameW: CGFloat = 0, detailW: CGFloat = 0
        for (_, t) in rows {
            let parts = t.string.components(separatedBy: "\t")
            nameW = max(nameW, width(parts[0]))
            detailW = max(detailW, width(parts.dropFirst().joined()))
        }
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: ceil(nameW + 24 + detailW))]
        for (item, t) in rows {
            let n = NSMutableAttributedString(attributedString: t)
            n.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: n.length))
            item.attributedTitle = n
        }
    }

    private func info(_ title: String, mark: Mark? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = mark?.image
        return item
    }

    private static func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    // MARK: 동작

    @objc private func openApp() {
        NSWorkspace.shared.openApplication(at: AgentService.mainAppURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 본체 설정 창만 띄운다 (본체가 inas://settings 를 받아 처리)
    @objc private func openSettings() {
        guard let url = URL(string: "inas://settings") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: AgentService.mainAppURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 본체가 inas://detail/<폴더>?tab=N 을 받아 그 폴더 상세 창을 연다
    @objc private func openDetail(_ sender: NSMenuItem) {
        guard let rest = sender.representedObject as? String, let url = URL(string: "inas://detail/" + rest) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: AgentService.mainAppURL, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func revealFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    @objc private func rescan(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Task { await AgentService.shared.sync.engine.requestScan(id, nil) }
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
