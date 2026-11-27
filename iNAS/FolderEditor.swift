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

    /// 키 아이디 → 기기 이름
    private var peerNames: [String: String] {
        var out: [String: String] = [:]
        for p in agent.sync?.peers ?? [] {
            if let k = p.keyID { out[k] = p.device.name }
        }
        return out
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
                        FolderStatusRows(status: agent.sync?.folderStatus[folderID], peerNames: peerNames)
                    }
                }
            } header: {
                Text("이 Mac (\(DeviceInfo.computerName))")
            } footer: {
                Text("이 설정은 이 Mac 에만 저장됩니다. 파일은 iCloud 를 거치지 않고, 같은 iCloud 계정의 Mac 끼리 암호화 연결로 바로 주고받습니다.")
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

/// 폴더 동기화 상태 줄들
private struct FolderStatusRows: View {
    let status: SyncFolderStatus?
    let peerNames: [String: String]

    private func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    var body: some View {
        if let s = status {
            LabeledContent("상태") {
                Text(stateText(s)).foregroundStyle(stateColor(s))
            }
            LabeledContent("이 Mac", value: "\(s.localFiles.formatted())개 · \(size(s.localBytes))")
            if s.peerNeed.isEmpty {
                LabeledContent("같이 쓰는 기기", value: "연결된 기기 없음")
            } else {
                ForEach(s.peerNeed.keys.sorted(), id: \.self) { key in
                    let n = s.peerNeed[key] ?? 0
                    LabeledContent(peerNames[key] ?? "다른 Mac") {
                        Text(n == 0 ? "맞춰짐" : "받을 것 \(n.formatted())개").foregroundStyle(n == 0 ? Color.green : Color.orange)
                    }
                }
            }
            if let last = s.lastSync {
                LabeledContent("마지막 동기화", value: last.formatted(date: .abbreviated, time: .standard))
            }
            if let e = s.lastError {
                Text(e).foregroundStyle(.red).textSelection(.enabled)
            }
        } else {
            LabeledContent("상태", value: "준비 중")
        }
    }

    private func stateText(_ s: SyncFolderStatus) -> String {
        switch s.state {
        case .stopped: return "멈춤"
        case .scanning: return "훑는 중"
        case .syncing: return "받는 중 — \(s.needItems.formatted())개 · \(size(s.needBytes))"
        case .waiting: return "준비 중"
        case .idle:
            if s.peerNeed.isEmpty { return "다른 Mac 을 기다림" }
            return s.peerNeed.values.allSatisfy { $0 == 0 } ? "맞춰짐" : "보내는 중"
        }
    }

    private func stateColor(_ s: SyncFolderStatus) -> Color {
        switch s.state {
        case .stopped: return .red
        case .idle: return s.peerNeed.isEmpty ? .secondary : (s.peerNeed.values.allSatisfy { $0 == 0 } ? .green : .orange)
        default: return .orange
        }
    }
}
