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
                Text("시험 기능입니다. 앱이 떠 있는 동안 1분마다 공인 IP · 포트를 확인해 iCloud 에 올리고, 다른 기기에 붙어 봅니다. 아직 파일은 주고받지 않습니다.")
            }

            Section {
                if sync.peers.isEmpty {
                    Text(sync.iCloudOK ? "같은 iCloud 에 다른 기기가 아직 없습니다." : "iCloud 에서 목록을 받지 못했습니다.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sync.peers) { peer in
                        PeerRow(peer: peer, me: sync.me, inbound: sync.inbound[peer.id])
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

/// 다른 기기 한 대: 이름 · 종류 · 주소, 이쪽 → 저쪽, 저쪽 → 이쪽
private struct PeerRow: View {
    let peer: SyncDevice
    let me: SyncDevice
    let inbound: (Date, String)?

    private var stale: Bool { Date().timeIntervalSince(peer.updatedAt) > 5 * 60 }

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
            ReachLine(title: "\(me.name) → \(peer.name)", reach: me.reach[peer.id])
            ReachLine(title: "\(peer.name) → \(me.name)", reach: peer.reach[me.id])
            if let inbound {
                Text("받은 연결: \(inbound.0.shortStamp) · \(inbound.1)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ReachLine: View {
    let title: String
    let reach: SyncReach?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(reach == nil ? Color.gray : (reach!.ok ? Color.green : Color.red)).frame(width: 7, height: 7)
            Text(title).font(.callout)
            Spacer()
            Group {
                if let r = reach {
                    Text(r.ok ? "연결됨 \(r.ms)ms · \(r.via)" : "실패 · \(r.via) · \(r.error ?? "")")
                } else {
                    Text("아직 안 해 봄")
                }
            }
            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
