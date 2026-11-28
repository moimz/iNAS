import SwiftUI

/// 폴더 상세 창: 설정 창처럼 위에 툴바 탭 [탐색 | 받기 | 보내기], 탭마다 요약 한 줄 + 창을 채우는 표.
/// 창이 열려 있는 동안 에이전트에서 1초마다 받아 온다(SyncFolderDetail).
/// 기록은 에이전트 메모리에만 있어 에이전트가 다시 뜨면 새로 쌓인다(사용자 2026-11-28).
/// 재탐색 간격은 폴더 설정 › 이 Mac 칸에 있다.
struct FolderDetailView: View {
    let folderID: String
    @EnvironmentObject private var folders: SyncFolderStore
    @EnvironmentObject private var agent: AgentClient
    @State private var detail: SyncFolderDetail?
    @AppStorage("folderDetailTab") private var tab = 0

    private static let tabs: [WindowToolbarTabs.Tab] = [
        .init(title: "탐색", symbol: "magnifyingglass"),
        .init(title: "받기", symbol: "arrow.down.circle"),
        .init(title: "보내기", symbol: "arrow.up.circle"),
    ]

    private var folderName: String { folders.folder(folderID)?.name ?? "폴더" }

    /// 키 아이디 → 기기 이름
    private var peerNames: [String: String] {
        var out: [String: String] = [:]
        for p in agent.sync?.peers ?? [] { if let k = p.keyID { out[k] = p.device.name } }
        return out
    }

    var body: some View {
        Group {
            switch tab {
            case 1:
                TransferTab(rows: detail?.receive ?? [], count: detail?.receiveCount ?? 0, bytes: detail?.receiveBytes ?? 0,
                            empty: "받을 것이 없습니다.", summary: "받을 것", peerNames: peerNames)
            case 2:
                TransferTab(rows: detail?.send ?? [], count: detail?.sendCount ?? 0, bytes: detail?.sendBytes ?? 0,
                            empty: "보낼 것이 없습니다.", summary: "보낼 것", peerNames: peerNames)
            default:
                ScanTab(folderID: folderID, detail: detail, peerNames: peerNames)
            }
        }
        .frame(minWidth: 720, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .background(WindowToolbarTabs(tabs: Self.tabs, selection: $tab))
        .navigationTitle("\(folderName) — \(Self.tabs[min(max(tab, 0), 2)].title)")
        .task {
            while !Task.isCancelled {
                if let d = await agent.folderDetail(folderID) { detail = d }
                try? await Task.sleep(for: .seconds(1))
            }
        }
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
    let folderID: String
    let detail: SyncFolderDetail?
    let peerNames: [String: String]
    @EnvironmentObject private var agent: AgentClient

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
        case .event: return "이 Mac · 변경 신호"
        case .rescan: return "이 Mac · 재탐색"
        case .peer(let k): return "\(peerNames[k] ?? "다른 Mac") 에서 받음"
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
                Button("지금 재탐색") { agent.syncCommand(.rescan(folderID)) }
                    .disabled(detail?.scan.phase == .full)
            }
            Table(detail?.changes ?? []) {
                TableColumn("시각") { c in
                    Text(stamp(c.date)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 110, max: 140)
                TableColumn("무엇") { c in
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
    let peerNames: [String: String]

    private static func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

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
                    Text(peerNames[r.peer] ?? "다른 Mac").lineLimit(1)
                }
                .width(min: 70, ideal: 100, max: 160)
                TableColumn("진행") { r in
                    HStack(spacing: 8) {
                        ProgressView(value: r.total > 0 ? min(1, Double(r.done) / Double(r.total)) : 0)
                            .frame(width: 80)
                        Text(r.total > 0 ? "\(Self.size(r.done)) / \(Self.size(r.total))" : "지움")
                            .monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                }
                .width(min: 200, ideal: 230)
            }
        }
    }
}
