import SwiftUI

/// 설정 > 동기화: 같은 iCloud 의 기기마다 칸 하나 (이 기기가 맨 위).
/// 동기화는 상주 에이전트가 돌리고, 이 화면은 에이전트가 보낸 상태(SyncSnapshot)를 보여 준다. 기록은 설정 > 기록.
struct SyncSettingsPage: View {
    @EnvironmentObject private var agent: AgentClient
    @State private var removing: SyncSnapshot.Peer?

    var body: some View {
        if let sync = agent.sync {
            form(sync)
        } else {
            ContentUnavailableView("동기화 상태를 받는 중", systemImage: "arrow.triangle.2.circlepath",
                                   description: Text("상주 에이전트와 연결되면 보입니다."))
                .onAppear { agent.connect() }
        }
    }

    private func form(_ sync: SyncSnapshot) -> some View {
        Form {
            DeviceSection(device: sync.me, isMe: true, keyID: sync.keyID,
                          reachOK: sync.inboundOK, reachText: sync.inboundText, busy: sync.busy,
                          onRefresh: { agent.syncCommand(.refresh) })
            ForEach(sync.peers) { peer in
                DeviceSection(device: peer.device, isMe: false, keyID: peer.keyID,
                              reachOK: peer.reachOK, reachText: peer.reachText, busy: false,
                              blockedKey: peer.blockedKey,
                              onRemove: { removing = peer },
                              onRestore: { agent.syncCommand(.restoreDevice($0)) })
            }
            if !sync.blocked.isEmpty {
                Section {
                    ForEach(sync.blocked) { b in
                        LabeledContent {
                            Button("다시 허용") { agent.syncCommand(.restoreDevice(b.keyID)) }
                        } label: {
                            Text(b.name)
                            Text("\(b.revokedAt.shortStamp) 지움 · 키 \(DeviceSection.fingerprint(b.keyID))")
                        }
                    }
                } header: {
                    Text("지운 기기")
                } footer: {
                    Text("지운 기기의 키는 차단되어, 그 Mac 이 다시 기록을 올려도 연결하지 않습니다.")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "이 기기를 지울까요?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { peer in
            Button("\(peer.device.name) 지우기", role: .destructive) { agent.syncCommand(.removeDevice(peer.device.id)) }
        } message: { peer in
            Text("\(peer.device.name) 의 기록을 iCloud 에서 지우고 키를 차단합니다. 연결은 바로 끊깁니다. 그 Mac 의 파일은 건드리지 않습니다. 실수로 지웠으면 \"다시 허용\" 으로 되돌릴 수 있습니다.")
        }
    }
}

/// 기기 한 대의 칸: 제목 = [아이콘] 이름 (이 기기) [새로 고침] / [기기 지우기…]
private struct DeviceSection: View {
    let device: SyncDevice
    let isMe: Bool
    let keyID: String?
    let reachOK: Bool?
    let reachText: String
    let busy: Bool
    var blockedKey: String?
    var onRefresh: () -> Void = {}
    var onRemove: () -> Void = {}
    var onRestore: (String) -> Void = { _ in }

    /// 키 아이디 앞 16자리를 4자리씩
    static func fingerprint(_ keyID: String) -> String {
        let c = Array(keyID.prefix(16))
        return stride(from: 0, to: c.count, by: 4).map { String(c[$0..<min($0 + 4, c.count)]) }.joined(separator: " ")
    }

    private var ipText: String {
        guard !device.publicIP.isEmpty else { return "—" }
        if !device.localIP.isEmpty, device.localIP != device.publicIP {
            return "\(device.publicIP) (내부 \(device.localIP))"
        }
        return device.publicIP
    }

    private var stale: Bool { !isMe && Date().timeIntervalSince(device.updatedAt) > SyncDiscovery.staleAfter }

    var body: some View {
        Section {
            LabeledContent("종류") {
                Text(verbatim: device.model.isEmpty ? device.modelID : device.model)
            }
            LabeledContent("IP") {
                Text(verbatim: ipText).textSelection(.enabled)
            }
            LabeledContent("포트") {
                Text(verbatim: device.port == 0 ? "—" : "\(device.publicIP):\(String(device.port))").textSelection(.enabled)
            }
            LabeledContent("접속 가능 여부") {
                HStack(spacing: 6) {
                    Circle().fill(reachOK == true ? Color.green : (reachOK == false ? Color.red : Color.gray)).frame(width: 7, height: 7)
                    Text(reachText)
                }
            }
            if stale {
                LabeledContent("마지막 소식") {
                    Text(device.updatedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.orange)
                }
            }
            if let blockedKey {
                LabeledContent("상태") {
                    HStack {
                        Text("차단됨").foregroundStyle(.red)
                        Button("다시 허용") { onRestore(blockedKey) }
                    }
                }
            }
            LabeledContent("키 지문") {
                Text(verbatim: keyID.map(Self.fingerprint) ?? "—").monospaced().textSelection(.enabled)
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: device.symbolName)
                Text(device.name)
                if isMe { Text("(이 기기)").foregroundStyle(.secondary) }
                Spacer()
                if isMe {
                    if busy { ProgressView().controlSize(.small) }
                    Button("새로 고침", action: onRefresh).disabled(busy)
                } else if blockedKey == nil {
                    Button("기기 지우기…", role: .destructive, action: onRemove)
                }
            }
        }
    }
}
