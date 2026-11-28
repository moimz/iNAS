import AppKit
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

/// 사이드바에서 고른 것: 서버 또는 동기화 폴더
enum SidebarItem: Hashable {
    case server(UUID)
    case folder(String)
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ServerStore
    @EnvironmentObject private var folders: SyncFolderStore
    @State private var selection: SidebarItem?
    @State private var deleteServer: ServerConfig?
    @State private var deleteFolder: SyncFolder?

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
            } detail: {
                switch selection {
                case .server(let id):
                    if let index = store.index(of: id) {
                        ServerEditor(original: store.servers[index]).id(id)
                    } else {
                        empty
                    }
                case .folder(let id):
                    if folders.folder(id) != nil {
                        FolderEditor(folderID: id, onDelete: { deleteFolder = folders.folder(id) }).id(id)
                    } else {
                        empty
                    }
                case nil:
                    empty
                }
            }
        }
        .onAppear {
            if selection == nil { selection = store.servers.first.map { .server($0.id) } }
        }
        .task {
            // 자동 연결은 창 없이 돌아서 권한을 물을 수 없으므로, 창이 열릴 때 미리 받아 둔다.
            if store.notifyAfterLoginMount {
                await Notifier.requestAuthorizationIfNeeded()
            }
        }
        .confirmationDialog(
            "이 서버를 삭제할까요?",
            isPresented: Binding(get: { deleteServer != nil }, set: { if !$0 { deleteServer = nil } }),
            presenting: deleteServer
        ) { server in
            Button("\(server.displayName) 삭제", role: .destructive) {
                store.remove(id: server.id)
                if selection == .server(server.id) { selection = store.servers.first.map { .server($0.id) } }
            }
        } message: { _ in
            Text("키체인에 저장한 비밀번호도 함께 지웁니다. 이미 연결된 공유는 그대로 둡니다.")
        }
        .confirmationDialog(
            "이 폴더를 삭제할까요?",
            isPresented: Binding(get: { deleteFolder != nil }, set: { if !$0 { deleteFolder = nil } }),
            presenting: deleteFolder
        ) { folder in
            Button("\(folder.name) 삭제", role: .destructive) {
                folders.delete(folder.id)
                if selection == .folder(folder.id) { selection = nil }
            }
        } message: { _ in
            Text("iCloud 로 모든 Mac 의 폴더 목록에서 빠집니다. 각 Mac 의 로컬 폴더와 그 안의 파일은 그대로 둡니다.")
        }
    }

    private var empty: some View {
        ContentUnavailableView(
            "서버나 폴더를 선택하세요",
            systemImage: "externaldrive.connected.to.line.below",
            description: Text("사이드바 위쪽 + 버튼으로 서버나 동기화 폴더를 추가할 수 있습니다.")
        )
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
                            Text(server.shares.isEmpty ? "선택한 공유폴더 없음" : "공유폴더 \(server.shares.count)개")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ConnectionDot(mounted: mounted, total: server.shares.count)
                    }
                    .tag(SidebarItem.server(server.id))
                    .contextMenu {
                        Button("서버 삭제…") { deleteServer = server }
                    }
                }
            }
            if !folders.folders.isEmpty {
                Section("폴더") {
                    ForEach(folders.folders) { folder in
                        FolderRow(folder: folder, setting: folders.setting(folder.id))
                            .tag(SidebarItem.folder(folder.id))
                            .contextMenu {
                                Button("폴더 삭제…") { deleteFolder = folder }
                            }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                AddMenuButton(
                    addServer: {
                        let server = ServerConfig.blank()
                        store.upsert(server)
                        selection = .server(server.id)
                    },
                    addFolder: {
                        selection = .folder(folders.add().id)
                    }
                )
            }
        }
    }
}

/// 사이드바 폴더 줄: 이름 · 이 Mac 에서 켜졌는지와 로컬 폴더
private struct FolderRow: View {
    let folder: SyncFolder
    let setting: LocalFolderSetting
    @Environment(\.backgroundProminence) private var prominence

    private var detail: String {
        guard setting.enabled else { return "이 Mac 에서 꺼짐" }
        guard let path = setting.path else { return "로컬 폴더 선택 안 함" }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        HStack {
            Image(systemName: setting.enabled ? "folder.fill" : "folder")
                .foregroundStyle(prominence == .increased ? Color.white : (setting.enabled ? Color.accentColor : Color.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name.isEmpty ? "이름 없음" : folder.name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// 사이드바 제목 줄의 + : 누르면 "서버 추가 / 폴더 추가" 메뉴 (툴바에 SwiftUI Menu 는 모양을 못 다뤄 NSMenu 로, Ai/iSQL.md 툴바 규칙)
private struct AddMenuButton: View {
    let addServer: () -> Void
    let addFolder: () -> Void

    var body: some View {
        Button {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("서버 추가", image: "externaldrive.badge.plus", action: addServer))
            menu.addItem(ClosureMenuItem("폴더 추가", image: "folder.badge.plus", action: addFolder))
            guard let event = NSApp.currentEvent, let view = event.window?.contentView else {
                menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                return
            }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } label: {
            Image(systemName: "plus")
        }
        .help("서버 또는 폴더 추가")
    }
}

/// 누르면 클로저를 부르는 메뉴 항목
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, image: String? = nil, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let image { self.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
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
                .help(mounted == total ? "공유폴더 \(total)개 모두 연결됨" : "공유폴더 \(total)개 중 \(mounted)개 연결됨")
        }
    }
}
