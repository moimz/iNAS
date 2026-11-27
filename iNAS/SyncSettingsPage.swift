import SwiftUI

/// 설정 > 동기화 (시험): 이 기기 · 같은 iCloud 의 기기와 서로 연결 · 기록
struct SyncSettingsPage: View {
    @EnvironmentObject private var sync: SyncDiscovery

    var body: some View {
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
                        Text(me.port == 0 ? "—" : "\(me.publicIP):\(me.port)").textSelection(.enabled)
                        Text(me.portMethod).font(.caption).foregroundStyle(me.reachable ? Color.green : Color.orange)
                            .multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("iCloud") {
                    Text(sync.iCloudStatus).foregroundStyle(sync.iCloudOK ? Color.secondary : Color.orange)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                HStack {
                    Text("이 기기")
                    Spacer()
                    if sync.busy { ProgressView().controlSize(.small) }
                    Button("지금 새로 고침") { Task { await sync.refresh() } }.disabled(sync.busy)
                }
            } footer: {
                Text("시험 기능입니다. 앱이 떠 있는 동안 공인 IP · 포트를 확인해 iCloud 에 올리고, 포트를 못 연 쪽이 연 쪽에 붙어 연결을 유지합니다(10초마다 신호). 아직 파일은 주고받지 않습니다.")
            }

            Section {
                if sync.peers.isEmpty {
                    Text(sync.iCloudOK ? "같은 iCloud 에 다른 기기가 아직 없습니다." : "iCloud 에서 목록을 받지 못했습니다.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sync.peers) { peer in
                        PeerRow(peer: peer, me: sync.me)
                    }
                }
            } header: {
                Text("같은 iCloud 의 기기")
            }

            Section {
                if sync.log.isEmpty {
                    Text("아직 기록이 없습니다.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(sync.log.prefix(40).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.0.shortStamp).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .leading)
                            Text(item.1).font(.callout).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } header: {
                Text("기록")
            }
        }
        .formStyle(.grouped)
    }
}

/// 다른 기기 한 대: 이름 · 종류 · 주소, 역할, 이쪽에서 본 연결, 저쪽에서 본 연결
private struct PeerRow: View {
    @EnvironmentObject private var sync: SyncDiscovery
    let peer: SyncDevice
    let me: SyncDevice

    private var stale: Bool { Date().timeIntervalSince(peer.updatedAt) > SyncDiscovery.staleAfter }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: peer.model.contains("MacBook") ? "laptopcomputer" : "desktopcomputer")
                Text(peer.name).font(.headline)
                Text(peer.model).foregroundStyle(.secondary)
                Spacer()
                Text(stale ? "\(peer.updatedAt.shortStamp) 뒤로 소식 없음" : "\(peer.updatedAt.shortStamp) 갱신")
                    .font(.caption).foregroundStyle(stale ? Color.orange : Color.secondary)
            }
            Text("공인 \(peer.publicIP.isEmpty ? "—" : peer.publicIP):\(peer.port) · 내부 \(peer.localIP):\(peer.internalPort) · \(peer.portMethod)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("\(peer.os) · iNAS \(peer.appVersion)").font(.caption).foregroundStyle(.secondary)
            Text("역할: \(sync.role(for: peer).text)").font(.callout)
            LinkLine(title: "\(me.name) 이 본 연결", link: me.links[peer.id])
            LinkLine(title: "\(peer.name) 이 본 연결", link: peer.links[me.id])
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
