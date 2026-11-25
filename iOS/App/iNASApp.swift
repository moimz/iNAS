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
    @State private var message: String?
    /// 썸네일 캐시 크기 (바이트, 모르면 nil)
    @State private var cacheSize: Int64?
    /// 썸네일을 못 만든 최근 기록
    @State private var failures = ThumbnailFailures.all()
    /// 모든 서버에서 받아 둔 파일 크기 (바이트, 모르면 nil)
    @State private var downloadedSize: Int64?
    /// 받아 둔 파일을 비우는 중
    @State private var evicting = false
    @Environment(\.scenePhase) private var scenePhase

    private func serverName(_ id: String) -> String {
        servers.first { $0.id == id }?.name ?? "지운 서버"
    }

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
                            }
                    }
                } header: {
                    Text("서버")
                } footer: {
                    Text("파일 앱 › 둘러보기 › 위치에 서버마다 하나씩 나타납니다. 왼쪽으로 밀면 서버를 지울 수 있습니다.")
                }

                Section {
                    LabeledContent("받아 둔 파일", value: downloadedSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                    Button("받아 둔 파일 비우기", role: .destructive) { evictAll() }
                        .disabled(evicting || (downloadedSize ?? 0) == 0)
                } footer: {
                    Text("파일 앱에서 받아 두어 구름 표시가 없는 파일입니다. 비우면 다시 구름 표시가 되고 NAS 원본은 그대로이며, 열 때 다시 받습니다. 공간이 부족하면 아이폰이 알아서 비우기도 합니다.")
                }

                Section {
                    LabeledContent("썸네일 캐시", value: cacheSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                    Button("캐시 지우기", role: .destructive) {
                        ThumbnailCache.clear()
                        cacheSize = ThumbnailCache.size()
                    }
                    .disabled(cacheSize == 0)
                } footer: {
                    Text("파일 앱에 보이는 사진·동영상 썸네일을 iNAS 가 만들어 둔 것입니다. 지우면 다음에 볼 때 다시 만듭니다. (파일 앱이 따로 기억해 둔 썸네일은 남을 수 있습니다)")
                }

                Section {
                    if failures.isEmpty {
                        Text("없음").foregroundStyle(.secondary)
                    }
                    ForEach(failures) { failure in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(failure.name).lineLimit(1).truncationMode(.middle)
                            Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                            Text("\(serverName(failure.serverID)) · \((failure.path as NSString).deletingLastPathComponent) · \(failure.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    if !failures.isEmpty {
                        Button("기록 지우기", role: .destructive) {
                            ThumbnailFailures.clear()
                            failures = []
                        }
                    }
                } header: {
                    Text("썸네일 실패 기록")
                } footer: {
                    Text("썸네일을 만들지 못한 최근 \(ThumbnailFailures.limit)개입니다.")
                }

                // 버전은 화면 아래에 고정하지 않고 목록 맨 끝에 (사용자 2026-11-26)
                Section {
                } footer: {
                    Text(Self.versionText).font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
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
            .task {
                await syncDomains()
                cacheSize = ThumbnailCache.size()
                await refreshDownloaded()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                cacheSize = ThumbnailCache.size()
                failures = ThumbnailFailures.all()
                Task { await refreshDownloaded() }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("확인", role: .cancel) {}
            }
        }
    }

    static var versionText: String {
        let info = Bundle.main.infoDictionary
        return "버전 \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    private func save(_ server: NASServer, password: String?) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) { servers[index] = server } else { servers.append(server) }
        ServerStore.save(servers)
        if let password { PasswordStore.set(password, for: server.id) }
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
        ThumbnailFailures.clear(serverID: server.id)
        ThumbnailCache.clear(serverID: server.id)
        NSFileProviderManager.remove(server.domain) { _ in }
    }

    /// 모든 서버에서 받아 둔 파일을 비운다 (목록은 그대로, 다시 열면 다시 받음)
    private func evictAll() {
        evicting = true
        Task {
            var failed = 0
            for server in servers { failed += await DownloadedFiles.evictAll(in: server.domain) }
            evicting = false
            if failed > 0 { message = "받아 둔 파일 \(failed)개를 비우지 못했습니다. (열려 있거나 아직 NAS 에 올리는 중인 파일)" }
            await refreshDownloaded()
        }
    }

    private func refreshDownloaded() async {
        var total: Int64 = 0
        for server in servers { total += await DownloadedFiles.size(of: server.domain) ?? 0 }
        downloadedSize = total
    }

    /// 서버 목록과 파일 앱 위치를 맞춘다: 목록에 없는 위치는 지우고, 빠진 서버는 등록한다
    private func syncDomains() async {
        await Self.removeLegacyLock(servers)
        await Self.reregisterForNFDFilenames(servers)
        await Self.reregister(servers, once: "noTrash")
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

    /// 파일 앱 이름을 NFD 로 바꾼 뒤 한 번 (2026-11-25): 이미 디스크에 NFC 이름으로 받아 둔 파일·폴더가 남지 않게
    /// 위치를 지웠다 다시 등록한다 (지울 때 시스템이 받아 둔 파일도 함께 지운다, 다시 열면 다시 받음)
    private static func reregisterForNFDFilenames(_ servers: [NASServer]) async {
        let key = "nfdFilenames"
        guard !Shared.defaults.bool(forKey: key) else { return }
        for server in servers {
            try? await NSFileProviderManager.remove(server.domain)
            try? await NSFileProviderManager.add(server.domain)
        }
        Shared.defaults.set(true, forKey: key)
    }

    /// 위치 설정(휴지통 등)을 바꾼 뒤 한 번: 위치를 지웠다 다시 등록해 새 설정이 들어가게 한다
    private static func reregister(_ servers: [NASServer], once key: String) async {
        guard !Shared.defaults.bool(forKey: key) else { return }
        for server in servers {
            try? await NSFileProviderManager.remove(server.domain)
            try? await NSFileProviderManager.add(server.domain)
        }
        Shared.defaults.set(true, forKey: key)
    }

    /// 잠금 기능을 뺀 뒤 한 번: 예전에 잠금 폴더가 있던 서버는 파일 앱 위치를 지웠다 다시 등록해
    /// 번호 붙은 잠금 폴더 식별자("Book|3")가 남지 않게 하고, 잠금 관련 설정을 지운다
    private static func removeLegacyLock(_ servers: [NASServer]) async {
        let defaults = Shared.defaults
        guard !defaults.bool(forKey: "lockRemoved") else { return }
        let raw = defaults.data(forKey: "servers").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        let hadLocks = Set(raw.compactMap { entry -> String? in
            guard let id = entry["id"] as? String, let locked = entry["locked"] as? [String], !locked.isEmpty else { return nil }
            return id
        })
        for server in servers where hadLocks.contains(server.id) {
            try? await NSFileProviderManager.remove(server.domain)
            try? await NSFileProviderManager.add(server.domain)
        }
        for server in servers {
            for key in ["lockEpoch", "unlockedUntil", "authRequested", "askedFolder"] { defaults.removeObject(forKey: "\(key).\(server.id)") }
        }
        defaults.removeObject(forKey: "lockMinutes")
        PasswordStore.delete(for: "lockPIN")
        ServerStore.save(servers)   // 저장하면서 JSON 의 "locked" 가 빠진다
        defaults.set(true, forKey: "lockRemoved")
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

// MARK: - 앱에서 쓰는 SMB (공유 목록)

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
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(id), displayName: name)
        // 바뀜 (2026-11-26): 휴지통은 만들지 않았다 (지우면 NAS 에서 바로 지움). 기본값(지원함)이면 파일 앱이
        // 1초마다 iNAS 휴지통을 찾다 "지원되지 않는 기능" 오류를 내고, 그때마다 받는 중 진행 표시를 다시 붙였다.
        domain.supportsSyncingTrash = false
        return domain
    }

    var address: String {
        host + (port.map { ":\($0)" } ?? "")
    }

    /// 목록에 보일 "아이디@주소:포트"
    var loginAddress: String {
        username.isEmpty ? address : "\(username)@\(address)"
    }
}

/// 받아 둔(구름 표시가 없는) 파일 크기. 시스템이 기억하는 "내려받은 항목" 목록에서 파일 크기를 더한다
/// (폴더를 직접 훑으면 받지 않은 NAS 폴더까지 읽게 되어서).
enum DownloadedFiles {
    static func size(of domain: NSFileProviderDomain) async -> Int64? {
        await files(of: domain)?.reduce(0) { $0 + $1.size }
    }

    /// 바뀜 (2026-11-26): 위치 맨 위를 통째로 비우면(evictItem rootContainer) "작업이 허용되지 않음" 으로 실패했다
    /// → 받아 둔 파일을 하나씩 비운다. 실패한 개수를 돌려준다.
    static func evictAll(in domain: NSFileProviderDomain) async -> Int {
        guard let manager = NSFileProviderManager(for: domain), let files = await files(of: domain) else { return 0 }
        var failed = 0
        for file in files {
            do { try await manager.evictItem(identifier: file.id) } catch { failed += 1 }
        }
        return failed
    }

    /// 받아 둔 파일들 (식별자, 디스크에서 차지하는 크기)
    private static func files(of domain: NSFileProviderDomain) async -> [(id: NSFileProviderItemIdentifier, size: Int64)]? {
        guard let manager = NSFileProviderManager(for: domain) else { return nil }
        let enumerator = manager.enumeratorForMaterializedItems()
        defer { enumerator.invalidate() }
        var files: [(id: NSFileProviderItemIdentifier, size: Int64)] = []
        var page = NSFileProviderPage(Data())
        while true {
            let observer = PageObserver()
            let result = await withCheckedContinuation { continuation in
                observer.done = { continuation.resume(returning: $0) }
                enumerator.enumerateItems(for: observer, startingAt: page)
            }
            guard let (items, next) = result else { return nil }
            // 이 목록의 항목엔 크기가 없다 → 디스크에 받아 둔 실제 파일에서 읽는다
            for item in items where !(item.contentType?.conforms(to: .folder) ?? false) {
                guard let url = try? await manager.getUserVisibleURL(for: item.itemIdentifier) else { continue }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                let size = values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
                files.append((item.itemIdentifier, Int64(size)))
            }
            guard let next else { return files }
            page = next
        }
    }

    private final class PageObserver: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
        var items: [NSFileProviderItem] = []
        var done: (([NSFileProviderItem], NSFileProviderPage?)?) -> Void = { _ in }

        func didEnumerate(_ updatedItems: [NSFileProviderItemProtocol]) {
            items.append(contentsOf: updatedItems)
        }

        func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
            done((items, nextPage))
        }

        func finishEnumeratingWithError(_ error: Error) {
            done(nil)
        }
    }
}
