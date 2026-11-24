import AMSMB2
import FileProvider
import SwiftUI

/// iNAS 아이폰·아이패드 앱: NAS 서버를 등록하면 서버마다 파일 앱 "위치"가 하나씩 생긴다.
/// 실제 파일 탐색·내려받기·올리기는 파일 앱 안에서 파일 제공 확장(iNASFileProvider)이 한다.
@main
struct INASApp: App {
    var body: some Scene {
        WindowGroup { ServerListView() }
    }
}

// MARK: - 서버 목록

struct ServerListView: View {
    @State private var servers = ServerStore.all()
    @State private var editing: NASServer?
    @State private var lockMinutes = Shared.lockMinutes
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if servers.isEmpty {
                        Text("오른쪽 위 + 를 눌러 NAS 서버를 추가하세요.").foregroundStyle(.secondary)
                    }
                    ForEach(servers) { server in
                        Button { editing = server } label: { ServerRow(server: server) }
                            .foregroundStyle(.primary)
                            .swipeActions {
                                Button(role: .destructive) { remove(server) } label: { Label("삭제", systemImage: "trash") }
                                Button { evict(server) } label: { Label("받은 파일 비우기", systemImage: "icloud.and.arrow.up") }
                                    .tint(.orange)
                            }
                    }
                } header: {
                    Text("서버")
                } footer: {
                    Text("파일 앱 › 둘러보기 › 위치에 서버마다 하나씩 나타납니다. 왼쪽으로 밀면 받아 둔 파일을 비우거나 서버를 지울 수 있습니다.")
                }

                Section {
                    Picker("잠금 유지 시간", selection: $lockMinutes) {
                        Text("없음 (매번 확인)").tag(0)
                        ForEach([1, 5, 15, 30, 60], id: \.self) { Text("\($0)분").tag($0) }
                    }
                    .onChange(of: lockMinutes) { _, value in Shared.lockMinutes = value }
                } header: {
                    Text("잠금 폴더")
                } footer: {
                    Text(lockMinutes == 0
                         ? "잠금 폴더는 들어갈 때마다 Face ID 로 확인합니다."
                         : "잠금 폴더는 Face ID 로 열고, 마지막으로 쓴 뒤 이 시간이 지나면 다시 잠깁니다.")
                }
            }
            .navigationTitle("iNAS")
            .toolbar {
                Button { editing = NASServer() } label: { Image(systemName: "plus") }
            }
            .sheet(item: $editing) { server in
                ServerEditor(server: server, isNew: !servers.contains { $0.id == server.id }) { saved, password in
                    save(saved, password: password)
                }
            }
            .task { await syncDomains() }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("확인", role: .cancel) {}
            }
        }
    }

    private func save(_ server: NASServer, password: String?) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) { servers[index] = server } else { servers.append(server) }
        ServerStore.save(servers)
        if let password { PasswordStore.set(password, for: server.id) }
        LockState.lock(server.id)
        // 이름·공유가 바뀌었을 수 있어 위치를 지우고 다시 등록한다
        let domain = server.domain
        NSFileProviderManager.remove(domain) { _ in
            NSFileProviderManager.add(domain) { error in
                Task { @MainActor in
                    if let error { message = "위치를 등록하지 못했습니다: \(error.localizedDescription)" }
                }
            }
        }
    }

    private func remove(_ server: NASServer) {
        servers.removeAll { $0.id == server.id }
        ServerStore.save(servers)
        PasswordStore.delete(for: server.id)
        LockState.lock(server.id)
        NSFileProviderManager.remove(server.domain) { _ in }
    }

    /// 이 서버에서 받아 둔 파일을 모두 비운다 (목록은 그대로, 다시 열면 다시 받음)
    private func evict(_ server: NASServer) {
        guard let manager = NSFileProviderManager(for: server.domain) else { return }
        manager.evictItem(identifier: .rootContainer) { error in
            Task { @MainActor in
                if let error { message = "받은 파일을 비우지 못했습니다: \(error.localizedDescription)" }
            }
        }
    }

    /// 서버 목록과 파일 앱 위치를 맞춘다: 목록에 없는 위치는 지우고, 빠진 서버는 등록한다
    private func syncDomains() async {
        let ids = Set(servers.map(\.id))
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        for domain in domains where !ids.contains(domain.identifier.rawValue) {
            try? await NSFileProviderManager.remove(domain)
        }
        let registered = Set(domains.map(\.identifier.rawValue))
        for server in servers where !registered.contains(server.id) {
            try? await NSFileProviderManager.add(server.domain)
        }
    }
}

private struct ServerRow: View {
    let server: NASServer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.headline).lineLimit(1)
                Text(server.loginAddress).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            // 파일 앱에 연결한 공유 수
            Text("\(server.shares.count)").font(.headline).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 서버 편집

struct ServerEditor: View {
    @State var server: NASServer
    let isNew: Bool
    let onSave: (NASServer, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var portText = ""
    @State private var available: [String] = []
    @State private var loading = false
    @State private var status: String?
    @State private var pickingFolder = false

    private var hasSavedPassword: Bool { PasswordStore.password(for: server.id) != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("서버") {
                    TextField("표시 이름 (예: 집 NAS)", text: $server.name)
                    TextField("주소 (예: nas.example.com)", text: $server.host)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("포트 (비우면 445)", text: $portText).keyboardType(.numberPad)
                    TextField("아이디", text: $server.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(hasSavedPassword ? "비밀번호 (바꿀 때만)" : "비밀번호", text: $password)
                }

                Section {
                    Button {
                        Task { await loadShares() }
                    } label: {
                        HStack {
                            Text(available.isEmpty ? "연결하고 공유 불러오기" : "공유 다시 불러오기")
                            if loading { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(server.host.isEmpty || loading)
                    ForEach(shareChoices, id: \.self) { share in
                        Toggle(isOn: shareBinding(share)) {
                            HStack {
                                Text(share)
                                if !available.isEmpty && !available.contains(share) {
                                    Text("서버에 없음").font(.caption).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                } header: {
                    Text("파일 앱에 보일 공유")
                } footer: {
                    Text(status ?? "켠 공유만 파일 앱에 폴더로 보입니다.")
                }

                Section {
                    ForEach(server.locked, id: \.self) { path in
                        Label(path, systemImage: "lock.fill")
                    }
                    .onDelete { server.locked.remove(atOffsets: $0) }
                    Button("잠글 폴더 고르기…") { pickingFolder = true }
                        .disabled(server.shares.isEmpty || server.host.isEmpty)
                } header: {
                    Text("잠금 폴더 (Face ID)")
                } footer: {
                    Text("고른 폴더와 그 안쪽은 Face ID 로 열고, \(Shared.lockMinutes)분 동안 쓰지 않으면 다시 잠깁니다. 왼쪽으로 밀면 잠금을 풉니다.")
                }
            }
            .navigationTitle(isNew ? "새 서버" : server.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        applyPort()
                        onSave(server, password.isEmpty ? nil : password)
                        dismiss()
                    }
                    .disabled(server.name.trimmingCharacters(in: .whitespaces).isEmpty || server.host.isEmpty || server.shares.isEmpty)
                }
            }
            .sheet(isPresented: $pickingFolder) {
                FolderPicker(client: client(), shares: server.shares) { path in
                    if !server.locked.contains(path) { server.locked.append(path) }
                }
            }
            .onAppear { portText = server.port.map(String.init) ?? "" }
        }
    }

    /// 서버에서 불러온 공유 + 이미 고른 공유 (서버에 없어진 것도 끌 수 있게)
    private var shareChoices: [String] {
        var list = available
        for share in server.shares where !list.contains(share) { list.append(share) }
        return list
    }

    private func shareBinding(_ share: String) -> Binding<Bool> {
        Binding(
            get: { server.shares.contains(share) },
            set: { on in
                if on {
                    server.shares.append(share)
                } else {
                    server.shares.removeAll { $0 == share }
                    server.locked.removeAll { $0 == share || $0.hasPrefix(share + "/") }
                }
            }
        )
    }

    private func applyPort() {
        server.host = server.host.trimmingCharacters(in: .whitespaces)
        server.name = server.name.trimmingCharacters(in: .whitespaces)
        server.port = Int(portText.trimmingCharacters(in: .whitespaces))
    }

    private func client() -> SMBBrowser {
        applyPort()
        return SMBBrowser(host: server.host, port: server.port, username: server.username,
                          password: password.isEmpty ? (PasswordStore.password(for: server.id) ?? "") : password)
    }

    private func loadShares() async {
        loading = true
        defer { loading = false }
        do {
            available = try await client().shares()
            status = available.isEmpty ? "공유가 없습니다." : "연결됨 · 공유 \(available.count)개"
        } catch {
            status = "연결 실패: \(SMBBrowser.describe(error))"
        }
    }
}

// MARK: - 잠글 폴더 고르기

private struct FolderPicker: View {
    let client: SMBBrowser
    let shares: [String]
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(shares, id: \.self) { share in
                NavigationLink(value: share) { Label(share, systemImage: "folder") }
            }
            .navigationTitle("잠글 폴더")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { path in
                FolderLevel(client: client, path: path) { picked in
                    onPick(picked)
                    dismiss()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
            }
        }
    }
}

private struct FolderLevel: View {
    let client: SMBBrowser
    let path: String
    let onPick: (String) -> Void
    @State private var folders: [String]?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Button { onPick(path) } label: { Label("이 폴더 잠그기", systemImage: "lock.fill") }
            }
            Section {
                if let folders {
                    if folders.isEmpty { Text("하위 폴더 없음").foregroundStyle(.secondary) }
                    ForEach(folders, id: \.self) { name in
                        NavigationLink(value: path + "/" + name) { Label(name, systemImage: "folder") }
                    }
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .task {
            do { folders = try await client.folders(in: path) } catch { self.error = SMBBrowser.describe(error) }
        }
    }
}

// MARK: - 앱에서 쓰는 SMB (공유 목록·폴더 고르기)

struct SMBBrowser {
    let host: String
    let port: Int?
    let username: String
    let password: String

    private func manager() throws -> SMB2Manager {
        var components = URLComponents()
        components.scheme = "smb"
        components.host = host
        components.port = port
        guard let url = components.url,
              let manager = SMB2Manager(url: url, credential: URLCredential(user: username, password: password, persistence: .forSession))
        else { throw POSIXError(.EINVAL) }
        manager.timeout = 15
        return manager
    }

    func shares() async throws -> [String] {
        try await manager().listShares().map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// "공유/경로" 안의 하위 폴더 이름
    func folders(in path: String) async throws -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        let manager = try manager()
        try await manager.connectShare(name: parts[0])
        let entries = try await manager.contentsOfDirectory(atPath: "/" + parts.dropFirst().joined(separator: "/"))
        return entries.compactMap { entry -> String? in
            guard let name = entry[.nameKey] as? String, (entry[.isDirectoryKey] as? Bool) == true,
                  !name.hasPrefix("."), !name.hasPrefix("@"), name != "#recycle" else { return nil }
            return name
        }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// libsmb2 오류를 사람이 읽을 문장으로 (inPlayer 와 같은 판별)
    static func describe(_ error: Error) -> String {
        guard let posix = error as? POSIXError else { return error.localizedDescription }
        let text = posix.localizedDescription.uppercased()
        if ["LOGON_FAILURE", "WRONG_PASSWORD", "ACCOUNT_"].contains(where: text.contains) { return "아이디 또는 비밀번호가 맞지 않습니다." }
        if [.ETIMEDOUT, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ECONNREFUSED, .EPERM].contains(posix.code) { return "서버에 연결할 수 없습니다. 주소와 포트를 확인하세요." }
        return posix.localizedDescription
    }
}

extension NASServer {
    var domain: NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(id), displayName: name)
    }

    var address: String {
        host + (port.map { ":\($0)" } ?? "")
    }

    /// 목록에 보일 "아이디@주소:포트"
    var loginAddress: String {
        username.isEmpty ? address : "\(username)@\(address)"
    }
}
