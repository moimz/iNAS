import SwiftUI

/// 설정 > 기록: [서버 기록 | 동기화 기록] (애플 기본 TabView — 박스 위에 탭이 걸친 모양, Ai/iSQL.md 툴바 규칙)
struct LogsSettingsPage: View {
    @EnvironmentObject private var agent: AgentClient
    @AppStorage("logsTabIndex") private var tab = 0

    var body: some View {
        // 설정 창 안에서 SwiftUI TabView 를 쓰면 탭이 창 위 아이콘 줄로 올라가거나, 다른 탭을 봤다 오면 탭 이름이 "서…" 로 잘린다
        // → AppKit 탭 상자(BoxTabView · RetilingTabView). Ai.md 12번
        BoxTabView(titles: ["서버 기록", "동기화 기록"], selection: $tab) { i in
            if i == 0 {
                AnyView(LogList(lines: (agent.status?.events ?? []).map { LogLine(date: $0.date, level: $0.level, text: $0.text) },
                                empty: "아직 서버 기록이 없습니다."))
            } else {
                AnyView(LogList(lines: (agent.sync?.log ?? []).map { LogLine(date: $0.date, level: .info, text: $0.text) },
                                empty: "아직 동기화 기록이 없습니다."))
            }
        }
        .padding(20)
        .onAppear { agent.connect() }
    }
}

private struct LogLine: Identifiable {
    let id = UUID()
    let date: Date
    let level: AgentEvent.Level
    let text: String
}

/// 날짜 줄로 묶은 기록: ───── 2026년 11월 28일 ───── 아래에 "13:29 ● 내용"
private struct LogList: View {
    let lines: [LogLine]
    let empty: String

    private struct Day: Identifiable {
        let date: Date
        let lines: [LogLine]
        var id: Date { date }
    }

    private var days: [Day] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: lines) { cal.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { d in Day(date: d, lines: groups[d]!.sorted { $0.date > $1.date }) }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일 EEEE"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        if lines.isEmpty {
            Text(empty).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(days) { day in
                        HStack(spacing: 10) {
                            VStack { Divider() }
                            Text(Self.dayFormatter.string(from: day.date))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                            VStack { Divider() }
                        }
                        .padding(.top, day.date == days.first?.date ? 0 : 8)
                        ForEach(day.lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Self.timeFormatter.string(from: line.date))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .leading)
                                Circle().fill(color(line.level)).frame(width: 7, height: 7)
                                Text(line.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func color(_ level: AgentEvent.Level) -> Color {
        switch level {
        case .ok: return .green
        case .warn: return .orange
        case .info: return .secondary
        }
    }
}
