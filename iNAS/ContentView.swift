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
        }
        .onAppear {
            if selection == nil { selection = store.servers.first?.id }
        }
        .task {
            // 자동 연결은 창 없이 돌아서 권한을 물을 수 없으므로, 창이 열릴 때 미리 받아 둔다.
            if store.notifyAfterLoginMount {
                await Notifier.requestAuthorizationIfNeeded()
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("서버") {
                ForEach(store.servers) { server in
                    let mounted = model.mountedCount(server)
                    HStack {
                        ServerRowIcon(enabled: server.enabled)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.displayName)
                            Text(server.shares.isEmpty ? "선택한 공유 없음" : "공유 \(server.shares.count)개")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ConnectionDot(mounted: mounted, total: server.shares.count)
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

/// 사이드바 서버 줄 오른쪽의 연결 상태 점: 모두 연결 초록 · 일부만 주황 · 하나도 없으면 없음
struct ConnectionDot: View {
    let mounted: Int
    let total: Int

    var body: some View {
        if total > 0, mounted > 0 {
            Circle()
                .fill(mounted == total ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .help(mounted == total ? "공유 \(total)개 모두 연결됨" : "공유 \(total)개 중 \(mounted)개 연결됨")
        }
    }
}
