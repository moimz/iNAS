import SwiftUI

/// 동기화 폴더 설정: 위는 모든 Mac 공통(iCloud), 아래는 이 Mac 만
struct FolderEditor: View {
    static let rescanChoices: [(Int, String)] = [(0, "끄기"), (30, "30분마다"), (60, "1시간마다"), (120, "2시간마다"),
                                                 (360, "6시간마다"), (720, "12시간마다"), (1440, "24시간마다")]
    @EnvironmentObject private var folders: SyncFolderStore
    @EnvironmentObject private var agent: AgentClient
    let folderID: String
    let onDelete: () -> Void
    @State private var name = ""
    @State private var ignores = ""
    @Environment(\.openWindow) private var openWindow
    @AppStorage(FolderDetailView.tabRequestKey) private var tabRequest = ""

    /// 상세 창을 열며 이 탭을 보여 달라 (이미 열린 창이면 그 창이 받아 탭을 바꾼다)
    private func openDetail(tab: Int) {
        let target = FolderDetailTarget(folderID: folderID, peer: nil)
        tabRequest = target.key + "#\(tab)"
        openWindow(id: "folderDetail", value: target)
    }

    private var setting: LocalFolderSetting { folders.setting(folderID) }

    private var status: SyncFolderStatus? { agent.sync?.folderStatus[folderID] }

    /// 이 Mac 의 상태
    private var myState: (kind: SyncStateSymbol.Kind, text: String) {
        guard let s = status else { return (.waiting, "준비 중") }
        if s.state == .stopped || s.lastError != nil { return (.problem, "멈춤") }
        if s.state == .scanning { return (.syncing, "훑는 중") }
        if s.state == .syncing || s.needItems > 0 {
            return (.syncing, s.needItems > 0 ? "받는 중 \(s.needItems.formatted())개" : "맞추는 중")
        }
        if s.peerNeed.isEmpty { return (.waiting, "다른 Mac 을 기다림") }
        return (.synced, "맞춰짐")
    }

    /// 이 폴더를 쓰는 다른 Mac (iCloud 기록 + 지금 연결된 기기), 지운 기기는 빼고
    private var otherDevices: [SyncSnapshot.Peer] {
        let connected = Set(status?.peerNeed.keys.map { $0 } ?? [])
        return (agent.sync?.peers ?? []).filter { p in
            p.blockedKey == nil && (p.device.folders[folderID] != nil || p.keyID.map { connected.contains($0) } == true)
        }
    }

    private func peerState(_ p: SyncSnapshot.Peer) -> (kind: SyncStateSymbol.Kind, text: String, count: String?) {
        let last = p.device.folders[folderID]?.lastSync.map { " · 마지막 동기화 \($0.shortStamp)" } ?? ""
        guard setting.enabled, setting.path != nil else { return (.waiting, "이 Mac 은 동기화 꺼짐" + last, nil) }
        guard let key = p.keyID, let s = status, let need = s.peerNeed[key] else { return (.offline, "연결 안 됨" + last, nil) }
        let count = s.peerFiles[key].map { FolderStatusLine.count(files: $0, bytes: s.peerBytes[key] ?? 0) }
        return need == 0 ? (.synced, "맞춰짐", count) : (.syncing, "받는 중 \(need.formatted())개", count)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("고유값") {
                    Text(folderID)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                TextField("폴더명", text: $name, prompt: Text("예: Projects"))
                    .onChange(of: name) { _, new in folders.rename(folderID, to: new) }
            } header: {
                Text("폴더")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("고유값과 폴더명은 iCloud 로 모든 Mac 에서 같게 보입니다. 각 Mac 이 고른 로컬 폴더는 이름이 달라도 이 폴더 아래에서 서로 동기화됩니다.")
                    if folders.unsynced.contains(folderID) {
                        Text("이 폴더는 아직 iCloud 에 올라가지 않았습니다.").foregroundStyle(.orange)
                    }
                    if let error = folders.iCloudError {
                        Text(error).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
            }

            Section {
                TextEditor(text: $ignores)
                    .font(.body.monospaced())
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
                    .onChange(of: ignores) { _, new in folders.setIgnores(folderID, new) }
            } header: {
                Text("동기화 예외")
            } footer: {
                Text("모든 Mac 에 같게 적용됩니다(iCloud). 한 줄에 하나씩, Syncthing 의 .stignore 와 같은 문법: *.tmp · /build(맨 위만) · !keep.tmp(예외에서 빼기) · (?d)(폴더를 지울 때 같이 지워도 됨) · // 주석.")
            }

            Section {
                Toggle("동기화", isOn: Binding(
                    get: { setting.enabled },
                    set: { folders.setEnabled(folderID, $0) }
                ))
                if setting.enabled {
                    LabeledContent("로컬 폴더") {
                        HStack(spacing: 8) {
                            if let path = folders.resolvedPath(folderID) {
                                Text((path as NSString).abbreviatingWithTildeInPath)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                                    .help(path)
                            } else {
                                Text("선택 안 함").foregroundStyle(.orange)
                            }
                            Button(setting.path == nil ? "선택…" : "바꾸기…") { folders.chooseLocalFolder(folderID) }
                        }
                    }
                    if setting.path != nil {
                        // 변경 신호(FSEvents)로 놓친 것까지: 이 간격마다 폴더 전체를 다시 훑는다 (Syncthing 기본 1시간)
                        Picker("재탐색", selection: Binding(
                            get: { setting.rescanMinutes ?? 60 },
                            set: { folders.setRescanMinutes(folderID, $0) }
                        )) {
                            ForEach(Self.rescanChoices, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .help("파일 변경 신호로 놓친 것까지 찾도록 이 간격마다 폴더 전체를 다시 훑습니다")
                        let st = myState
                        FolderStatusLine(folderID: folderID, kind: st.kind, text: st.text,
                                         count: status.map { FolderStatusLine.count(files: $0.localFiles, bytes: $0.localBytes) })
                        // 충돌 사본은 상세 창 "충돌" 탭에서 관리 (여기는 있다는 것만)
                        if let n = status?.conflicts.count, n > 0 {
                            LabeledContent("충돌 사본") {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    Text("\(n.formatted())개").lineLimit(1).fixedSize()
                                    Button("관리…") { openDetail(tab: FolderDetailView.conflictTab) }
                                }
                            }
                        }
                        if let e = status?.lastError {
                            Text(e).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                }
            } header: {
                DeviceSectionTitle(symbol: agent.sync?.me.symbolName ?? "desktopcomputer", name: DeviceInfo.computerName, isMe: true)
            } footer: {
                Text("이 설정은 이 Mac 에만 저장됩니다. 파일은 iCloud 를 거치지 않고, 같은 iCloud 계정의 Mac 끼리 암호화 연결로 바로 주고받습니다.")
            }

            // 이 폴더를 쓰는 다른 Mac: iCloud 기기 기록(folders)에 이 폴더가 있거나 지금 이 폴더로 연결된 기기
            ForEach(otherDevices) { peer in
                Section {
                    let st = peerState(peer)
                    FolderStatusLine(folderID: folderID, peer: peer.keyID, kind: st.kind, text: st.text, count: st.count)
                } header: {
                    DeviceSectionTitle(symbol: peer.device.symbolName, name: peer.device.name)
                }
            }


        }
        .formStyle(.grouped)
        // 서버 화면과 같은 아래 막대 (폴더는 고치면 바로 저장돼 저장 버튼은 없다)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("폴더 삭제…", role: .destructive, action: onDelete)
                Spacer()
            }
            .padding(12)
            .background(.bar)
        }
        .onAppear {
            name = folders.folder(folderID)?.name ?? ""
            ignores = folders.folder(folderID)?.ignores ?? ""
        }
        .onChange(of: folders.folder(folderID)?.ignores) { _, new in
            if let new, new != ignores { ignores = new }
        }
        .onChange(of: folders.folder(folderID)?.name) { _, new in
            // 다른 Mac 에서 바꾼 이름이 들어오면 (내가 고치는 중이 아닐 때) 반영
            if let new, new != name { name = new }
        }
    }
}
