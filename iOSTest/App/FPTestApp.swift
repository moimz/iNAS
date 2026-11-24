import AMSMB2
import FileProvider
import SwiftUI

/// 시험용 앱: NAS 서버를 등록하면 서버마다 파일 앱 위치가 하나씩 생긴다.
@main
struct FPTestApp: App {
    var body: some Scene {
        WindowGroup { ServerListView() }
    }
}

struct ServerListView: View {
    @State private var servers = ServerStore.all()
    @State private var editing: NASServer?
    @State private var status = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(servers) { server in
                        Button {
                            editing = server
                        } label: {
                            VStack(alignment: .leading) {
                                Text(server.name).font(.headline)
                                Text("\(server.host)\(server.port.map { ":\($0)" } ?? "") · 공유 \(server.shares.joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if !server.locked.isEmpty {
                                    Text("잠금: \(server.locked.joined(separator: ", "))").font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        for server in offsets.map({ servers[$0] }) { remove(server) }
                    }
                } footer: {
                    Text(status)
                }
            }
            .navigationTitle("iNAS 시험")
            .toolbar {
                Button { editing = NASServer() } label: { Image(systemName: "plus") }
            }
            .sheet(item: $editing) { server in
                ServerEditor(server: server) { saved, password in
                    save(saved, password: password)
                }
            }
            .task { await cleanUpOldDomains() }
        }
    }

    private func domain(_ server: NASServer) -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(server.id), displayName: server.name)
    }

    private func save(_ server: NASServer, password: String?) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) { servers[index] = server } else { servers.append(server) }
        ServerStore.save(servers)
        if let password { PasswordStore.set(password, for: server.id) }
        LockState.lock(server.id)
        // 이름·공유가 바뀌었을 수 있어 위치를 지우고 다시 등록한다
        NSFileProviderManager.remove(domain(server)) { _ in
            NSFileProviderManager.add(domain(server)) { error in
                Task { @MainActor in status = error.map { "위치 등록 실패: \($0.localizedDescription)" } ?? "\"\(server.name)\" 위치를 등록했습니다." }
            }
        }
    }

    private func remove(_ server: NASServer) {
        servers.removeAll { $0.id == server.id }
        ServerStore.save(servers)
        PasswordStore.delete(for: server.id)
        NSFileProviderManager.remove(domain(server)) { _ in }
    }

    /// 1차 시험에서 만든 "iNAS 시험" 가짜 위치 등 서버 목록에 없는 위치를 지운다
    private func cleanUpOldDomains() async {
        let ids = Set(servers.map(\.id))
        guard let domains = try? await NSFileProviderManager.domains() else { return }
        for domain in domains where !ids.contains(domain.identifier.rawValue) {
            try? await NSFileProviderManager.remove(domain)
        }
    }
}

struct ServerEditor: View {
    @State var server: NASServer
    let onSave: (NASServer, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var portText = ""
    @State private var sharesText = ""
    @State private var lockedText = ""
    @State private var testResult = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("서버") {
                    TextField("표시 이름 (예: 집 NAS)", text: $server.name)
                    TextField("주소", text: $server.host).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("포트 (비우면 445)", text: $portText).keyboardType(.numberPad)
                    TextField("아이디", text: $server.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(PasswordStore.password(for: server.id) == nil ? "비밀번호" : "비밀번호 (바꿀 때만)", text: $password)
                }
                Section {
                    TextField("공유 (쉼표로 구분, 예: Media, Project)", text: $sharesText).textInputAutocapitalization(.never)
                    Button("공유 목록 불러오기") { Task { await loadShares() } }
                    if !testResult.isEmpty { Text(testResult).font(.caption) }
                } header: { Text("파일 앱에 보일 공유") }
                Section {
                    TextField("한 줄에 하나: 공유/폴더", text: $lockedText, axis: .vertical)
                        .textInputAutocapitalization(.never).lineLimit(2...6)
                } header: { Text("잠금 폴더 (Face ID)") } footer: {
                    Text("예: Project/인사 — 그 폴더와 안쪽은 Face ID 로 열고, \(Int(Shared.lockInterval / 60))분 동안 쓰지 않으면 다시 잠깁니다.")
                }
            }
            .navigationTitle(server.name.isEmpty ? "새 서버" : server.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        apply()
                        onSave(server, password.isEmpty ? nil : password)
                        dismiss()
                    }
                    .disabled(server.name.isEmpty || server.host.isEmpty)
                }
            }
            .onAppear {
                portText = server.port.map(String.init) ?? ""
                sharesText = server.shares.joined(separator: ", ")
                lockedText = server.locked.joined(separator: "\n")
            }
        }
    }

    private func apply() {
        server.port = Int(portText)
        server.shares = sharesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        server.locked = lockedText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.filter { !$0.isEmpty }
    }

    private func loadShares() async {
        apply()
        var components = URLComponents()
        components.scheme = "smb"
        components.host = server.host
        components.port = server.port
        let pass = password.isEmpty ? (PasswordStore.password(for: server.id) ?? "") : password
        guard let url = components.url,
              let manager = SMB2Manager(url: url, credential: URLCredential(user: server.username, password: pass, persistence: .forSession)) else {
            testResult = "주소가 올바르지 않습니다."
            return
        }
        testResult = "불러오는 중…"
        do {
            let shares = try await manager.listShares()
            testResult = "공유: " + shares.map(\.name).joined(separator: ", ")
        } catch {
            testResult = "실패: \(error.localizedDescription)"
        }
    }
}
