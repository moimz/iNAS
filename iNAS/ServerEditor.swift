import SwiftUI

struct ServerEditor: View {
    @EnvironmentObject private var store: ServerStore

    let original: ServerConfig
    @State private var draft: ServerConfig
    @State private var portText: String
    /// 비어 있으면 키체인의 기존 비밀번호를 그대로 쓴다.
    @State private var password = ""
    @State private var hasStoredPassword = false

    @State private var fetchedShares: [String]?
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testSucceeded = false
    @State private var manualShare = ""
    @State private var saveError: String?

    init(original: ServerConfig) {
        self.original = original
        _draft = State(initialValue: original)
        _portText = State(initialValue: original.port.map(String.init) ?? "")
    }

    private var isDirty: Bool { normalizedDraft != original || !password.isEmpty }

    private var normalizedDraft: ServerConfig {
        var d = draft
        let p = portText.trimmingCharacters(in: .whitespaces)
        d.port = p.isEmpty ? nil : Int(p)
        d.normalize()
        return d
    }

    private var canTest: Bool {
        let d = normalizedDraft
        return !d.host.isEmpty && !d.username.isEmpty && (!password.isEmpty || hasStoredPassword)
    }

    /// 서버에서 가져온 공유 + 이미 고른 공유
    private var shareChoices: [String] {
        var list = fetchedShares ?? []
        for s in draft.shares where !list.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) {
            list.append(s)
        }
        return list
    }

    var body: some View {
        Form {
            Section("서버") {
                TextField("표시 이름", text: $draft.name, prompt: Text("예: 집 NAS"))
                TextField("주소", text: $draft.host, prompt: Text("nas.example.com"))
                TextField("포트", text: $portText, prompt: Text("445 (기본값)"))
                Toggle("자동 연결에 포함", isOn: $draft.enabled)
            }

            Section {
                TextField("아이디", text: $draft.username)
                SecureField(
                    "비밀번호",
                    text: $password,
                    prompt: Text(hasStoredPassword ? "키체인에 저장됨 — 바꿀 때만 입력" : "비밀번호")
                )
            } header: {
                Text("계정")
            } footer: {
                Text("비밀번호는 로그인 키체인에만 저장합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        Text("접속 시험")
                    }
                    .disabled(!canTest || isTesting)
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                    if let testMessage {
                        Label(testMessage, systemImage: testSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(testSucceeded ? .green : .orange)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }

                if shareChoices.isEmpty {
                    Text("접속 시험을 눌러 공유 목록을 가져오세요.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shareChoices, id: \.self) { share in
                        Toggle(isOn: binding(for: share)) {
                            HStack {
                                Text(share)
                                if fetchedShares != nil,
                                   !(fetchedShares ?? []).contains(where: { $0.caseInsensitiveCompare(share) == .orderedSame }) {
                                    Text("서버 목록에 없음").font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }

                HStack {
                    TextField("공유 이름 직접 추가", text: $manualShare)
                        .onSubmit(addManualShare)
                    Button("추가", action: addManualShare)
                        .disabled(manualShare.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("자동 연결할 공유")
            } footer: {
                Text("체크한 공유만 \"지금 연결\"과 로그인 시 연결합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if let saveError {
                    Text(saveError).foregroundStyle(.red).font(.callout)
                }
                Spacer()
                Button("되돌리기") { revert() }
                    .disabled(!isDirty)
                Button("저장") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty)
            }
            .padding(12)
            .background(.bar)
        }
        .navigationTitle(draft.displayName)
        .onAppear {
            hasStoredPassword = Keychain.hasPassword(for: original.credentialKey)
        }
        .onDisappear {
            // 다른 서버를 고르거나 창을 닫으면 바뀐 내용을 저장한다.
            if isDirty, store.index(of: original.id) != nil { save() }
        }
    }

    private func binding(for share: String) -> Binding<Bool> {
        Binding {
            draft.shares.contains { $0.caseInsensitiveCompare(share) == .orderedSame }
        } set: { on in
            if on {
                // 서버 목록 순서를 유지한다.
                draft.shares.append(share)
                let order = shareChoices
                draft.shares.sort { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
            } else {
                draft.shares.removeAll { $0.caseInsensitiveCompare(share) == .orderedSame }
            }
        }
    }

    private func addManualShare() {
        let name = manualShare.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty else { return }
        if !draft.shares.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            draft.shares.append(name)
        }
        manualShare = ""
    }

    private func testConnection() async {
        let d = normalizedDraft
        let pw = password.isEmpty ? Keychain.password(for: d.credentialKey) : password
        guard let pw else {
            testSucceeded = false
            testMessage = "키체인에 이 주소·아이디의 비밀번호가 없습니다. 비밀번호를 입력하세요."
            return
        }
        isTesting = true
        testMessage = nil
        defer { isTesting = false }

        guard await Mounter.isReachable(host: d.host, port: d.port ?? 445, timeout: 5) else {
            testSucceeded = false
            testMessage = "\(d.hostAndPort)에 연결할 수 없습니다."
            return
        }
        do {
            let shares = try await SMBShareLister.listShares(host: d.host, port: d.port, username: d.username, password: pw)
            fetchedShares = shares
            testSucceeded = true
            testMessage = "접속 성공 — 공유 \(shares.count)개"
            // 접속에 성공한 비밀번호는 바로 키체인에 저장한다.
            if !password.isEmpty {
                save()
            }
        } catch {
            testSucceeded = false
            testMessage = error.localizedDescription
        }
    }

    private func save() {
        saveError = nil
        let updated = normalizedDraft
        let oldKey = original.credentialKey
        let newKey = updated.credentialKey
        do {
            if !password.isEmpty {
                try Keychain.setPassword(password, for: newKey)
                if oldKey != newKey { Keychain.deletePassword(for: oldKey) }
            } else if oldKey != newKey, let existing = Keychain.password(for: oldKey) {
                // 주소나 아이디가 바뀌면 키체인 항목도 옮긴다.
                try Keychain.setPassword(existing, for: newKey)
                Keychain.deletePassword(for: oldKey)
            }
        } catch {
            saveError = error.localizedDescription
            return
        }
        password = ""
        hasStoredPassword = Keychain.hasPassword(for: newKey)
        draft = updated
        portText = updated.port.map(String.init) ?? ""
        store.upsert(updated)
    }

    private func revert() {
        let current = store.servers.first { $0.id == original.id } ?? original
        draft = current
        portText = current.port.map(String.init) ?? ""
        password = ""
        saveError = nil
    }
}
