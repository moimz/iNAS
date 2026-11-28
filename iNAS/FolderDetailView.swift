import SwiftUI

/// 폴더 상세 창: [탐색 | 받기 | 보내기]. 창이 열려 있는 동안 에이전트에서 1초마다 받아 온다(SyncFolderDetail).
/// 기록은 에이전트 메모리에만 있어 에이전트가 다시 뜨면 새로 쌓인다(사용자 2026-11-28).
struct FolderDetailView: View {
    let folderID: String
    @EnvironmentObject private var folders: SyncFolderStore
    @EnvironmentObject private var agent: AgentClient
    @State private var detail: SyncFolderDetail?
    @AppStorage("folderDetailTab") private var tab = 0

    private var folderName: String { folders.folder(folderID)?.name ?? "폴더" }

    /// 키 아이디 → 기기 이름
    private var peerNames: [String: String] {
        var out: [String: String] = [:]
        for p in agent.sync?.peers ?? [] { if let k = p.keyID { out[k] = p.device.name } }
        return out
    }

    var body: some View {
        // 탭 상자는 SwiftUI TabView 대신 BoxTabView (창 · 시트 안에서 탭 이름이 잘리지 않게, Ai.md 12번)
        BoxTabView(titles: ["탐색", "받기", "보내기"], selection: $tab) { i in
            switch i {
            case 0: AnyView(ScanTab(folderID: folderID, detail: detail, peerNames: peerNames))
            case 1: AnyView(TransferTab(rows: detail?.receive ?? [], count: detail?.receiveCount ?? 0, bytes: detail?.receiveBytes ?? 0,
                                        peerTitle: "기기", empty: "받을 것이 없습니다.", summary: "받을 것", peerNames: peerNames))
            default: AnyView(TransferTab(rows: detail?.send ?? [], count: detail?.sendCount ?? 0, bytes: detail?.sendBytes ?? 0,
                                         peerTitle: "기기", empty: "보낼 것이 없습니다.", summary: "보낼 것", peerNames: peerNames))
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 460)
        .navigationTitle("\(folderName) — 상세")
        .task {
            while !Task.isCancelled {
                if let d = await agent.folderDetail(folderID) { detail = d }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

// MARK: 탐색

private struct ScanTab: View {
    let folderID: String
    let detail: SyncFolderDetail?
    let peerNames: [String: String]
    @EnvironmentObject private var folders: SyncFolderStore
    @EnvironmentObject private var agent: AgentClient

    private static let intervals: [(Int, String)] = [(0, "끄기"), (30, "30분"), (60, "1시간"), (120, "2시간"),
                                                       (360, "6시간"), (720, "12시간"), (1440, "24시간")]

    private var minutes: Binding<Int> {
        Binding(get: { folders.setting(folderID).rescanMinutes ?? 60 },
                set: { folders.setRescanMinutes(folderID, $0) })
    }

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
                t += " · 재탐색 꺼짐"
            }
            return t
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("재탐색").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Picker("", selection: minutes) {
                            ForEach(Self.intervals, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Text("마다 폴더 전체를 다시 훑습니다").foregroundStyle(.secondary)
                        Spacer()
                        Button("지금 재탐색") { agent.syncCommand(.rescan(folderID)) }
                            .disabled(detail?.scan.phase == .full)
                    }
                }
                GridRow {
                    Text("지금").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if let p = detail?.scan.phase, p != .idle {
                            SyncStateSymbol(kind: .syncing)
                        }
                        Text(nowText).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Divider()
            HStack {
                Text("최근 변경").font(.headline)
                Spacer()
                Text("이 Mac 에서 알아챈 것과 다른 Mac 에서 받은 것, 최근 \(SyncFolderDetail.changeLimit.formatted())개")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ChangeList(changes: detail?.changes ?? [], peerNames: peerNames)
        }
        .padding(12)
    }
}

/// 최근 변경: 날짜 줄 아래 "시각 · 무엇 · 경로 · 어디서" (설정 › 기록과 같은 모양)
private struct ChangeList: View {
    let changes: [SyncFolderDetail.Change]
    let peerNames: [String: String]

    private struct Day: Identifiable {
        let date: Date
        let items: [SyncFolderDetail.Change]
        var id: Date { date }
    }

    private var days: [Day] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: changes) { cal.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { Day(date: $0, items: groups[$0]!.sorted { $0.date > $1.date }) }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일 EEEE"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

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
        if changes.isEmpty {
            Text("아직 변경이 없습니다. (에이전트가 다시 뜨면 새로 쌓입니다)")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(days) { day in
                        HStack(spacing: 10) {
                            VStack { Divider() }
                            Text(Self.dayFormatter.string(from: day.date))
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                            VStack { Divider() }
                        }
                        .padding(.top, day.date == days.first?.date ? 0 : 8)
                        ForEach(day.items) { c in
                            let a = actionText(c.action)
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(Self.timeFormatter.string(from: c.date))
                                    .monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 64, alignment: .leading)
                                Text(a.0).foregroundStyle(a.1).frame(width: 30, alignment: .leading)
                                Text(c.path)
                                    .lineLimit(1).truncationMode(.middle)
                                    .textSelection(.enabled)
                                    .help(c.path)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(originText(c.origin))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1).fixedSize()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: 받기 · 보내기

private struct TransferTab: View {
    let rows: [SyncFolderDetail.Transfer]
    let count: Int
    let bytes: Int64
    let peerTitle: String
    let empty: String
    let summary: String
    let peerNames: [String: String]

    private static func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M/d HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(count == 0 ? empty : "\(summary) \(count.formatted())개 · \(Self.size(bytes))")
                    .foregroundStyle(count == 0 ? .secondary : .primary)
                Spacer()
                if count > rows.count {
                    Text("앞의 \(rows.count.formatted())개만 보여 줍니다").font(.caption).foregroundStyle(.secondary)
                }
            }
            Table(rows) {
                TableColumn("들어온 시각") { r in
                    Text(Self.stampFormatter.string(from: r.since)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 120, max: 140)
                TableColumn("파일") { r in
                    HStack(spacing: 6) {
                        if r.active { SyncStateSymbol(kind: .syncing) }
                        Text(r.path).lineLimit(1).truncationMode(.middle).help(r.path)
                    }
                }
                TableColumn(peerTitle) { r in
                    Text(peerNames[r.peer] ?? "다른 Mac").lineLimit(1)
                }
                .width(min: 80, ideal: 100, max: 160)
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
        .padding(12)
    }
}
