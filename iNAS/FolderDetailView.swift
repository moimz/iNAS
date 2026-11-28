import SwiftUI

/// 상세 창이 보여 줄 것: 폴더 + 어느 Mac (nil = 이 Mac, 아니면 그 기기 키 아이디)
struct FolderDetailTarget: Codable, Hashable {
    var folderID: String
    var peer: String?
    var key: String { folderID + "|" + (peer ?? "") }
}

/// 폴더 상세 창: 설정 창처럼 위에 툴바 탭 [탐색 | 받기 | 보내기 | 충돌], 탭마다 요약 한 줄 + 창을 채우는 표.
/// 창이 열려 있는 동안 에이전트에서 1초마다 받아 온다(SyncFolderDetail).
/// 다른 Mac 이면 에이전트가 동기화 연결로 그 Mac 에 달라고 해서 받아 온다(연결이 없으면 못 봄). 충돌 탭은 이 Mac 만
/// (충돌 사본도 동기화돼 양쪽에 같다).
/// 기록은 에이전트 메모리에만 있어 에이전트가 다시 뜨면 새로 쌓인다(사용자 2026-11-28).
/// 재탐색 간격은 폴더 설정 › 이 Mac 칸에 있다.
struct FolderDetailView: View {
    let target: FolderDetailTarget
    @EnvironmentObject private var folders: SyncFolderStore
    @EnvironmentObject private var agent: AgentClient
    @State private var detail: SyncFolderDetail?
    /// 다른 Mac 과 연결이 없어 못 받음
    @State private var unreachable = false
    @SceneStorage("folderDetailTab") private var tab = 0
    @AppStorage(Self.tabRequestKey) private var tabRequest = ""
    @Environment(\.openWindow) private var openWindow

    static let tabRequestKey = "folderDetailTabRequest"
    static let conflictTab = 3

    private var folderID: String { target.folderID }
    private var isMe: Bool { target.peer == nil }

    private var tabs: [WindowToolbarTabs.Tab] {
        var t: [WindowToolbarTabs.Tab] = [
            .init(title: "탐색", symbol: "magnifyingglass"),
            .init(title: "받기", symbol: "arrow.down.circle"),
            .init(title: "보내기", symbol: "arrow.up.circle"),
        ]
        if isMe { t.append(.init(title: "충돌", symbol: "exclamationmark.triangle")) }
        return t
    }

    private var shownTab: Int { min(max(tab, 0), tabs.count - 1) }

    private var folderName: String { folders.folder(folderID)?.name ?? "폴더" }

    /// 이 상세가 누구 것인가 (기기 이름)
    private var owner: String { target.peer.map { name(of: $0) } ?? myName }

    /// 이 Mac 의 기기 이름. 다른 Mac 의 상세를 볼 때 "이 Mac" 이 어느 쪽인지 헷갈려서 늘 이름으로 쓴다 (사용자 2026-11-29)
    private var myName: String { agent.sync.map { $0.me.name.isEmpty ? "이 Mac" : $0.me.name } ?? "이 Mac" }

    /// 키 아이디 → 기기 이름 (나도 이름으로)
    private func name(of keyID: String) -> String {
        if keyID == agent.sync?.keyID { return myName }
        return agent.sync?.peers.first { $0.keyID == keyID }?.device.name ?? "다른 Mac"
    }

    private var status: SyncFolderStatus? { agent.sync?.folderStatus[folderID] }

    var body: some View {
        Group {
            if !isMe, unreachable {
                notice("\(owner) 와(과) 연결돼 있지 않습니다.\n연결되면 \(owner) 에서 본 이 폴더의 상세를 보여 줍니다.")
            } else if !isMe, detail?.waiting ?? true {
                notice("\(owner) 에 묻는 중…")
            } else {
                switch shownTab {
                case 1:
                    TransferTab(rows: detail?.receive ?? [], count: detail?.receiveCount ?? 0, bytes: detail?.receiveBytes ?? 0,
                                empty: "받을 것이 없습니다.", summary: "받을 것", name: name(of:))
                case 2:
                    TransferTab(rows: detail?.send ?? [], count: detail?.sendCount ?? 0, bytes: detail?.sendBytes ?? 0,
                                empty: "보낼 것이 없습니다.", summary: "보낼 것", name: name(of:))
                case 3:
                    ConflictTab(root: folders.resolvedPath(folderID), conflicts: status?.conflicts ?? [],
                                devices: status?.conflictDevices ?? [:])
                default:
                    ScanTab(detail: detail, owner: owner, name: name(of:)) {
                        if let peer = target.peer {
                            agent.syncCommand(.rescanPeer(folderID, peer))
                        } else {
                            agent.syncCommand(.rescan(folderID))
                        }
                    }
                }
            }
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .background(WindowToolbarTabs(tabs: tabs, selection: $tab))
        .navigationTitle(isMe ? "\(folderName) — \(tabs[shownTab].title)" : "\(folderName) · \(owner) — \(tabs[shownTab].title)")
        .onAppear(perform: takeTabRequest)
        .onChange(of: tabRequest) { _, _ in takeTabRequest() }
        // 메인 창을 닫아 둔 채 메뉴 막대에서 다른 폴더 상세를 열 때를 위해 상세 창도 요청을 받는다 (먼저 받은 창이 연다)
        .onReceive(NotificationCenter.default.publisher(for: FolderDetailRequest.notification)) { _ in
            guard let r = FolderDetailRequest.take() else { return }
            tabRequest = r.target.key + "#\(r.tab)"
            openWindow(id: "folderDetail", value: r.target)
        }
        .task {
            while !Task.isCancelled {
                let d = await agent.folderDetail(folderID, peer: target.peer)
                if isMe {
                    if let d { detail = d }
                } else {
                    unreachable = d == nil
                    if let d, !(d.waiting && detail != nil) { detail = d }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// 폴더 설정의 [관리…] 처럼 "이 탭을 보여 달라" 가 이 창 앞으로 왔으면 받는다
    private func takeTabRequest() {
        let parts = tabRequest.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == target.key, let t = Int(parts[1]) else { return }
        tab = t
        tabRequest = ""
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 표 위 요약 한 줄
private struct SummaryBar<Trailing: View>: View {
    let content: AnyView
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            content
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

/// 시각: 오늘이면 "15:03:17", 아니면 "11/27 23:43:01"
private func stamp(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ko_KR")
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm:ss" : "M/d HH:mm:ss"
    return f.string(from: d)
}

// MARK: 탐색

private struct ScanTab: View {
    let detail: SyncFolderDetail?
    /// 이 상세의 주인 ("이 Mac" / 기기 이름)
    let owner: String
    let name: (String) -> String
    let rescan: () -> Void

    private var busy: Bool { (detail?.scan.phase ?? .idle) != .idle }

    private var nowText: String {
        guard let s = detail?.scan else { return "받는 중…" }
        let checked = s.checked > 0 ? " (\(s.checked.formatted())개 확인)" : ""
        let dir = (s.dir ?? "").isEmpty ? "맨 위" : s.dir!
        switch s.phase {
        case .events:
            return "변경 신호 처리 중 — \(dir)\(checked)" + (s.fullWaiting ? " · 전체 재탐색은 대기 중" : "")
        case .full:
            return "전체 재탐색 중 — \(dir)\(checked)"
        case .idle:
            if s.fullWaiting { return "전체 재탐색 대기 중" }
            var t = "쉼"
            if let last = s.lastFull { t += " · 마지막 재탐색 \(last.formatted(date: .omitted, time: .shortened))" }
            if s.interval > 0, let last = s.lastFull {
                t += " · 다음 \(last.addingTimeInterval(s.interval).formatted(date: .omitted, time: .shortened))"
            } else if s.interval == 0 {
                t += " · 정해진 재탐색 꺼짐"
            }
            return t
        }
    }

    private func actionText(_ a: SyncFolderDetail.Change.Action) -> (String, Color) {
        switch a {
        case .added: return ("추가", .green)
        case .modified: return ("고침", .accentColor)
        case .deleted: return ("지움", .red)
        }
    }

    private func originText(_ o: SyncFolderDetail.Change.Origin) -> String {
        switch o {
        case .event: return "\(owner) · 변경 신호"
        case .rescan: return "\(owner) · 재탐색"
        case .peer(let k): return "\(name(k)) 에서 받음"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SummaryBar(content: AnyView(
                HStack(spacing: 6) {
                    if busy { SyncStateSymbol(kind: .syncing) }
                    Text(nowText).lineLimit(1).truncationMode(.middle)
                }
            )) {
                Button("지금 재탐색", action: rescan)
                    .disabled(detail?.scan.phase == .full)
            }
            Table(detail?.changes ?? []) {
                TableColumn("시각") { c in
                    Text(stamp(c.date)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 110, max: 140)
                TableColumn("사유") { c in
                    let a = actionText(c.action)
                    Text(a.0).foregroundStyle(a.1)
                }
                .width(min: 36, ideal: 40, max: 60)
                TableColumn("경로") { c in
                    Text(c.path).lineLimit(1).truncationMode(.middle).help(c.path)
                }
                TableColumn("출처") { c in
                    Text(originText(c.origin)).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 100, ideal: 140, max: 220)
            }
            .overlay {
                if (detail?.changes ?? []).isEmpty {
                    Text("아직 바뀐 파일이 없습니다. 에이전트가 다시 뜨면 새로 쌓입니다.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: 받기 · 보내기

private struct TransferTab: View {
    let rows: [SyncFolderDetail.Transfer]
    let count: Int
    let bytes: Int64
    let empty: String
    let summary: String
    let name: (String) -> String

    /// 크기는 KB 부터 (647바이트 → 1KB, 0 → 0KB): "647바이트 / 647바이트" 처럼 길어지지 않게 (사용자 2026-11-29)
    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.allowsNonnumericFormatting = false
        return f
    }()
    private static func size(_ b: Int64) -> String { sizeFormatter.string(fromByteCount: b) }

    var body: some View {
        VStack(spacing: 0) {
            SummaryBar(content: AnyView(
                Text(count == 0 ? empty : "\(summary) \(count.formatted())개 · \(Self.size(bytes))")
                    .foregroundStyle(count == 0 ? .secondary : .primary)
            )) {
                if count > rows.count {
                    Text("앞의 \(rows.count.formatted())개만 보여 줍니다").font(.caption).foregroundStyle(.secondary)
                }
            }
            Table(rows) {
                TableColumn("들어온 시각") { r in
                    Text(stamp(r.since)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 110, max: 140)
                TableColumn("파일") { r in
                    HStack(spacing: 6) {
                        if r.active { SyncStateSymbol(kind: .syncing) }
                        Text(r.path).lineLimit(1).truncationMode(.middle).help(r.path)
                    }
                }
                TableColumn("기기") { r in
                    Text(name(r.peer)).lineLimit(1)
                }
                .width(min: 70, ideal: 100, max: 160)
                // 막대 [빈칸] 크기(오른쪽 맞춤). 막대는 짧게, 남는 폭은 파일 칸에
                TableColumn("진행") { r in
                    HStack(spacing: 8) {
                        ProgressBar(fraction: r.total > 0 ? min(1, Double(r.done) / Double(r.total)) : 0)
                            .frame(width: 90, height: 6)
                        Spacer(minLength: 4)
                        Text(r.total > 0 ? "\(Self.size(r.done)) / \(Self.size(r.total))" : "지움")
                            .monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                }
                .width(min: 210, ideal: 220, max: 240)
            }
        }
    }
}

/// 진행 막대. 표(Table) 줄은 다시 쓰여서 ProgressView 는 값이 바뀌어도 막대가 안 바뀌는 일이 있어 직접 그린다
/// (보내기 탭 "20KB / 20KB" 인데 막대가 거의 빈 채로 보임, 빌드 95)
private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(Color.accentColor)
                    .frame(width: max(0, min(1, fraction)) * g.size.width)
            }
        }
    }
}
