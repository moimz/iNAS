import SwiftUI

/// 동기화 폴더 설정: 위는 모든 Mac 공통(iCloud), 아래는 이 Mac 만
struct FolderEditor: View {
    @EnvironmentObject private var folders: SyncFolderStore
    @EnvironmentObject private var agent: AgentClient
    let folderID: String
    let onDelete: () -> Void
    @State private var name = ""
    @State private var ignores = ""

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
                        let st = myState
                        FolderStatusLine(kind: st.kind, text: st.text,
                                         count: status.map { FolderStatusLine.count(files: $0.localFiles, bytes: $0.localBytes) })
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
                    FolderStatusLine(kind: st.kind, text: st.text, count: st.count)
                } header: {
                    DeviceSectionTitle(symbol: peer.device.symbolName, name: peer.device.name)
                }
            }

            if setting.enabled, let root = folders.resolvedPath(folderID),
               let conflicts = agent.sync?.folderStatus[folderID]?.conflicts, !conflicts.isEmpty {
                ConflictSection(root: root, conflicts: conflicts)
            }

            Section {
                Button("폴더 삭제…", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
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
