import SwiftUI

/// 설정 > 동기화: 이 기기 · 같은 iCloud 의 기기(지우기 · 차단) · 기록.
/// 동기화는 상주 에이전트가 돌리고, 이 화면은 에이전트가 보낸 상태(SyncSnapshot)를 보여 준다.
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
            Section {
                let me = sync.me
                LabeledContent("이름", value: me.name)
                LabeledContent("종류", value: me.model == me.modelID ? me.model : "\(me.model) · \(me.modelID)")
                LabeledContent("내부 IP", value: me.localIP.isEmpty ? "—" : me.localIP)
                LabeledContent("공인 IP") {
                    Text(me.publicIP.isEmpty ? "—" : me.publicIP).textSelection(.enabled)
                }
                LabeledContent("대기") {
                    Text(sync.listenStatus).foregroundStyle(me.internalPort == 0 ? .red : .secondary)
                }
                LabeledContent("바깥 포트") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: me.port == 0 ? "—" : "\(me.publicIP):\(String(me.port))").textSelection(.enabled)
                        Text(me.portMethod).font(.caption).foregroundStyle(me.reachable ? Color.green : Color.orange)
                            .multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("들어오는 연결") {
                    Text(sync.inboundText).foregroundStyle(sync.inboundOK == true ? Color.green : (sync.inboundOK == false ? Color.red : Color.secondary))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("iCloud") {
                    Text(sync.iCloudStatus).foregroundStyle(sync.iCloudOK ? Color.secondary : Color.orange)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("키 지문", value: me.publicKey.isEmpty ? "—" : String(me.publicKey.prefix(12)))
            } header: {
                HStack {
                    Text("이 기기")
                    Spacer()
                    if sync.busy { ProgressView().controlSize(.small) }
                    Button("지금 새로 고침") { agent.syncCommand(.refresh) }.disabled(sync.busy)
                }
            } footer: {
                Text("상주 에이전트가 늘 공인 IP · 포트를 확인해 iCloud 에 올리고, 포트를 못 연 쪽이 연 쪽에 붙어 암호화 연결을 유지합니다. 같은 iCloud 계정의 기기만 믿습니다.")
            }

            Section {
                if sync.peers.isEmpty {
                    Text(sync.iCloudOK ? "같은 iCloud 에 다른 기기가 아직 없습니다." : "iCloud 에서 목록을 받지 못했습니다.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sync.peers) { peer in
                        PeerRow(peer: peer, me: sync.me, onRemove: { removing = peer },
                                onRestore: { agent.syncCommand(.restoreDevice($0)) })
                    }
                }
            } header: {
                Text("같은 iCloud 의 기기")
            } footer: {
                Text("팔았거나 더 이상 쓰지 않는 Mac 은 지우세요. 그 Mac 의 키를 차단해서, 옛 앱이 다시 기록을 올려도 연결하지 않습니다.")
            }

            if !sync.blocked.isEmpty {
                Section("지운 기기 (차단됨)") {
                    ForEach(sync.blocked) { b in
                        LabeledContent {
                            Button("다시 허용") { agent.syncCommand(.restoreDevice(b.keyID)) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.name)
                                Text("\(b.revokedAt.shortStamp) 지움 · 키 \(b.keyID.prefix(12))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                if sync.log.isEmpty {
                    Text("아직 기록이 없습니다.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(sync.log.prefix(40).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.date.shortStamp).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .leading)
                            Text(item.text).font(.callout).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } header: {
                Text("기록")
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

/// 다른 기기 한 대: 이름 · 종류 · 주소, 역할, 이쪽에서 본 연결, 저쪽에서 본 연결, 지우기
private struct PeerRow: View {
    let peer: SyncSnapshot.Peer
    let me: SyncDevice
    let onRemove: () -> Void
    let onRestore: (String) -> Void

    private var d: SyncDevice { peer.device }
    private var age: TimeInterval { Date().timeIntervalSince(d.updatedAt) }

    private var seen: (String, Color) {
        if age > 30 * 86400 { return ("\(d.updatedAt.formatted(date: .abbreviated, time: .omitted)) 뒤로 오래 안 보임", .red) }
        if age > SyncDiscovery.staleAfter { return ("\(d.updatedAt.shortStamp) 뒤로 소식 없음", .orange) }
        return ("\(d.updatedAt.shortStamp) 갱신", .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: d.model.contains("MacBook") ? "laptopcomputer" : "desktopcomputer")
                Text(d.name).font(.headline)
                Text(d.model).foregroundStyle(.secondary)
                Spacer()
                Text(seen.0).font(.caption).foregroundStyle(seen.1)
                Menu {
                    if let key = peer.blockedKey {
                        Button("다시 허용") { onRestore(key) }
                    } else {
                        Button("기기 지우기…", role: .destructive, action: onRemove)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Text(verbatim: "공인 \(d.publicIP.isEmpty ? "—" : d.publicIP):\(String(d.port)) · 내부 \(d.localIP):\(String(d.internalPort)) · \(d.portMethod)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("\(d.os) · iNAS \(d.appVersion)\(peer.keyID.map { " · 키 \($0.prefix(12))" } ?? "")").font(.caption).foregroundStyle(.secondary)
            if !d.folders.isEmpty {
                Text("폴더 \(d.folders.count)개 동기화 중").font(.caption).foregroundStyle(.secondary)
            }
            Text("역할: \(peer.role)").font(.callout).foregroundStyle(peer.blockedKey == nil ? Color.primary : Color.red)
            LinkLine(title: "\(me.name) 이 본 연결", link: me.links[d.id])
            LinkLine(title: "\(d.name) 이 본 연결", link: d.links[me.id])
        }
        .padding(.vertical, 2)
    }
}

private struct LinkLine: View {
    let title: String
    let link: SyncLinkInfo?

    private var detail: String {
        guard let l = link else { return "아직 없음" }
        let dir = l.outgoing ? "내가 붙음" : "붙어 옴"
        if l.up {
            var t = "연결됨 · \(dir) · \(l.via)"
            if let since = l.since { t += " · \(since.shortStamp)부터" }
            if let rtt = l.rtt { t += " · \(rtt)ms" }
            return t
        }
        return "끊김 · \(dir) · \(l.via) · \(l.error ?? "") (\(l.at.shortStamp))"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(link == nil ? Color.gray : (link!.up ? Color.green : Color.red)).frame(width: 7, height: 7)
            Text(title).font(.callout)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
