import SwiftUI

/// 사이드바 서버 행의 아이콘. 선택돼 강조색 배경이 칠해지면 그 배경에 묻히지 않게 흰색으로 바꾼다.
private struct ServerRowIcon: View {
    let enabled: Bool
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: enabled ? "server.rack" : "pause.circle")
            .foregroundStyle(prominence == .increased ? Color.white : (enabled ? Color.accentColor : Color.secondary))
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ServerStore
    @State private var selection: ServerConfig.ID?
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
            } detail: {
                if let id = selection, let index = store.index(of: id) {
                    ServerEditor(original: store.servers[index])
                        .id(id)
                } else {
                    ContentUnavailableView(
                        "서버를 선택하세요",
                        systemImage: "externaldrive.connected.to.line.below",
                        description: Text("왼쪽 아래 + 버튼으로 서버를 추가할 수 있습니다.")
                    )
                }
            }
            Divider()
            StatusBar()
        }
        .onAppear {
            if selection == nil { selection = store.servers.first?.id }
        }
        .task {
            // 로그인 연결은 창 없이 돌아서 권한을 물을 수 없으므로, 창이 열릴 때 미리 받아 둔다.
            if store.notifyAfterLoginMount {
                await Notifier.requestAuthorizationIfNeeded()
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("서버") {
                ForEach(store.servers) { server in
                    HStack {
                        ServerRowIcon(enabled: server.enabled)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.displayName)
                            Text(server.shares.isEmpty ? "선택한 공유 없음" : "공유 \(server.shares.count)개")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(server.id)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 2) {
                Button {
                    let server = ServerConfig.blank()
                    store.upsert(server)
                    selection = server.id
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 18)
                }
                .help("서버 추가")
                Button {
                    confirmDelete = true
                } label: {
                    Image(systemName: "minus").frame(width: 22, height: 18)
                }
                .help("선택한 서버 삭제")
                .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .confirmationDialog(
            "이 서버를 삭제할까요?",
            isPresented: $confirmDelete,
            presenting: selection.flatMap { id in store.servers.first { $0.id == id } }
        ) { server in
            Button("\(server.displayName) 삭제", role: .destructive) {
                store.remove(id: server.id)
                selection = store.servers.first?.id
            }
        } message: { _ in
            Text("키체인에 저장한 비밀번호도 함께 지웁니다. 이미 연결된 공유는 그대로 둡니다.")
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ServerStore
    @EnvironmentObject private var loginItem: LoginItemController
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                Toggle("로그인 시 자동 연결", isOn: Binding(
                    get: { loginItem.isOn },
                    set: { loginItem.setOn($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle("로그인 연결 후 알림", isOn: Binding(
                    get: { store.notifyAfterLoginMount },
                    set: { on in
                        store.notifyAfterLoginMount = on
                        if on { Task { await Notifier.requestAuthorization() } }
                    }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)

                Spacer()

                Button {
                    showDetails = true
                } label: {
                    Label(model.summary, systemImage: model.hasProblems ? "exclamationmark.triangle" : "checkmark.circle")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(model.hasProblems ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help("공유별 상태 보기")
                .popover(isPresented: $showDetails, arrowEdge: .top) {
                    ResultsView(states: model.shareStates, results: model.lastResults, date: model.lastRun)
                }

                Button {
                    model.mountNow()
                } label: {
                    if model.isMounting {
                        ProgressView().controlSize(.small).frame(width: 60)
                    } else {
                        Text("지금 연결")
                    }
                }
                .disabled(model.isMounting)
            }
            if let text = loginItem.statusText {
                HStack {
                    Text(text).font(.caption).foregroundStyle(.orange)
                    Button("시스템 설정 열기") { loginItem.openSystemSettings() }
                        .controlSize(.small)
                }
            }
            if let error = loginItem.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
            model.refreshMountState()
        }
    }
}

struct ResultsView: View {
    let states: [ShareState]
    let results: [ServerResult]
    let date: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("지금 상태").font(.headline)
            if states.isEmpty {
                row("자동 연결할 공유가 없습니다.", "minus.circle", .secondary)
            }
            ForEach(states) { state in
                if let path = state.mountPoint {
                    row("\(state.serverName) / \(state.share) — 연결됨 (\(path))", "checkmark.circle.fill", .green)
                } else {
                    row("\(state.serverName) / \(state.share) — 연결 안 됨", "circle.dashed", .orange)
                }
            }
            if let date {
                Divider()
                Text("\(date.formatted(date: .omitted, time: .standard)) \"지금 연결\" 결과")
                    .font(.headline)
            }
            ForEach(results) { result in
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.serverName).bold()
                    switch result.state {
                    case .unreachable:
                        row("서버에 닿지 않아 건너뛰었습니다.", "wifi.slash", .orange)
                    case .missingPassword:
                        row("키체인에 비밀번호가 없습니다.", "key", .orange)
                    case .nothingSelected:
                        row("자동 연결할 공유를 고르지 않았습니다.", "minus.circle", .secondary)
                    case .done:
                        ForEach(result.shares) { share in
                            switch share.outcome {
                            case .mounted(let path):
                                row("\(share.share) — 연결함 (\(path))", "checkmark.circle.fill", .green)
                            case .alreadyMounted:
                                row("\(share.share) — 이미 연결됨", "checkmark.circle", .secondary)
                            case .failed(let message):
                                row("\(share.share) — \(message)", "xmark.octagon.fill", .red)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 320, alignment: .leading)
    }

    private func row(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label {
            Text(text).textSelection(.enabled)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.callout)
    }
}
