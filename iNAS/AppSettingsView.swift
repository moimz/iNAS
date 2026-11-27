import AppKit
import SwiftUI

/// iNAS 설정 (⌘,, Settings 장면). iSQL AppSettingsView 와 같은 모양: 폭은 탭마다 같고 높이만 바뀐다.
/// 서버 하나하나의 설정은 메인 창에서, 여기는 앱 전체 설정.
struct AppSettingsView: View {
    static let width: CGFloat = 600
    @AppStorage("appSettingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("일반", systemImage: "gearshape", value: "general") {
                GeneralSettingsPage().frame(width: Self.width, height: 260)
            }
            Tab("서버", systemImage: "externaldrive.connected.to.line.below", value: "server") {
                ServerSettingsPage().frame(width: Self.width, height: 600)
            }
            Tab("동기화", systemImage: "arrow.triangle.2.circlepath", value: "sync") {
                SyncSettingsPage().frame(width: Self.width, height: 680)
            }
        }
        .background(SettingsWindowStyler())
    }
}

/// 설정 > 일반
private struct GeneralSettingsPage: View {
    var body: some View {
        Form {
            UpdateSection()
        }
        .formStyle(.grouped)
    }
}

/// 설정 > 일반 > 업데이트: 지금 버전, 자동 확인 켜기/끄기, 지금 확인 (Updater · Sparkle)
private struct UpdateSection: View {
    @Bindable private var updater = Updater.shared

    /// "2.3.1 (빌드 41 · abc1234)" — 정보 창과 같은 글
    private var version: String { AppVersion.text }

    var body: some View {
        Section {
            LabeledContent("버전") {
                HStack(spacing: 8) {
                    // 한 줄로 못 박지 않으면 줄바꿈될 수 있는 글로 재서 폭을 덜 받아 "…" 로 잘리고 버튼 오른쪽이 빈다 (Ai.md 12번)
                    Text(version).foregroundStyle(.secondary).monospacedDigit().textSelection(.enabled)
                        .lineLimit(1).fixedSize()
                    Button("업데이트 확인…") { updater.checkForUpdates() }.disabled(!updater.canCheck)
                }
            }
            Toggle("자동으로 업데이트 확인", isOn: $updater.automaticallyChecks)
        } header: {
            Text("업데이트")
        } footer: {
            Text("하루에 한 번 새 버전이 있는지 확인하고, 있으면 설치할지 묻습니다.")
        }
    }
}

/// 설정 > 서버: 자동 연결 토글 셋과 상주 에이전트의 최근 기록
private struct ServerSettingsPage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ServerStore
    @EnvironmentObject private var loginItem: LoginItemController
    @EnvironmentObject private var agent: AgentClient

    var body: some View {
        Form {
            Section {
                Toggle("시작 시 자동 연결", isOn: Binding(
                    get: { store.autoMountAtLogin },
                    set: { model.setAutoConnect(atLogin: $0) }
                ))
                Toggle("연결 해제 시 자동 연결", isOn: Binding(
                    get: { store.autoRemount },
                    set: { model.setAutoConnect(remount: $0) }
                ))
                Toggle("연결 후 알림 메시지 표시", isOn: Binding(
                    get: { store.notifyAfterLoginMount },
                    set: { on in
                        store.notifyAfterLoginMount = on
                        if on { Task { await Notifier.requestAuthorization() } }
                    }
                ))
                if let text = loginItem.statusText {
                    LabeledContent {
                        Button("시스템 설정 열기") { loginItem.openSystemSettings() }
                    } label: {
                        Text(text).foregroundStyle(.orange)
                    }
                }
                if let error = loginItem.lastError {
                    Text(error).foregroundStyle(.red)
                } else if loginItem.status == .enabled, !agent.isConnected {
                    Text("백그라운드 에이전트와 연결되지 않았습니다. 앱을 다시 열어 보세요.").foregroundStyle(.orange)
                }
            } header: {
                Text("자동 연결")
            } footer: {
                Text("시작 시: 로그인할 때 고른 공유를 연결합니다. 연결 해제 시: 잠자기에서 깨어날 때나 네트워크가 바뀔 때 빠진 공유를 다시 연결하고, 서버가 끊기면 돌아올 때까지 1분마다 다시 시도합니다. 직접 꺼낸 공유는 다음 깨어남까지 그대로 둡니다.")
            }

            Section {
                let events = agent.status?.events ?? []
                if events.isEmpty {
                    Text("아직 기록이 없습니다.").foregroundStyle(.secondary)
                } else {
                    ForEach(events.prefix(30)) { event in
                        EventRow(event: event)
                    }
                }
            } header: {
                Text("최근 기록")
            }
        }
        .formStyle(.grouped)
        .onAppear { agent.connect() }
    }
}

/// 최근 기록 한 줄: 시각 · 점 · 내용
private struct EventRow: View {
    let event: AgentEvent

    private var color: Color {
        switch event.level {
        case .ok: return .green
        case .warn: return .orange
        case .info: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.date.shortStamp)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Circle().fill(color).frame(width: 7, height: 7)
            Text(event.text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 설정 창을 맥 설정 창 모양(제목 아래 탭 막대, 구분선)으로 (iSQL SettingsWindowStyler 와 같다)
struct SettingsWindowStyler: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            DispatchQueue.main.async {
                w.styleMask.remove(.fullSizeContentView)
                w.titlebarAppearsTransparent = false
                w.titlebarSeparatorStyle = .line
                w.toolbarStyle = .preference
            }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ v: Probe, context: Context) {}
}
