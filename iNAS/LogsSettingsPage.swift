import SwiftUI

/// 설정 > 기록: [서버 기록 | 동기화 기록] (애플 기본 TabView — 박스 위에 탭이 걸친 모양, Ai/iSQL.md 툴바 규칙)
struct LogsSettingsPage: View {
    @EnvironmentObject private var agent: AgentClient
    @AppStorage("logsTab") private var tab = "server"

    var body: some View {
        TabView(selection: $tab) {
            LogList(lines: (agent.status?.events ?? []).map { LogLine(date: $0.date, level: $0.level, text: $0.text) },
                    empty: "아직 서버 기록이 없습니다.")
                .tabItem { Text("서버 기록") }
                .tag("server")
            LogList(lines: (agent.sync?.log ?? []).map { LogLine(date: $0.date, level: .info, text: $0.text) },
                    empty: "아직 동기화 기록이 없습니다.")
                .tabItem { Text("동기화 기록") }
                .tag("sync")
        }
        // 설정 창(Settings) 안의 기본 TabView 는 탭이 창 툴바로 올라가 버린다 → 박스 위에 걸친 모양(.grouped)
        .tabViewStyle(.grouped)
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

private struct LogList: View {
    let lines: [LogLine]
    let empty: String

    var body: some View {
        if lines.isEmpty {
            Text(empty).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Self.stamp(line.date))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 130, alignment: .leading)
                            Circle().fill(color(line.level)).frame(width: 7, height: 7)
                            Text(line.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    /// 오늘이면 "오후 1:29", 아니면 "11/27 오후 11:43" (한 줄)
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M/d a h:mm"
        return f
    }()

    static func stamp(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened) : dayFormatter.string(from: d)
    }

    private func color(_ level: AgentEvent.Level) -> Color {
        switch level {
        case .ok: return .green
        case .warn: return .orange
        case .info: return .secondary
        }
    }
}
