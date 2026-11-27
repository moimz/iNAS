import SwiftUI

/// 동기화 폴더 설정: 위는 모든 Mac 공통(iCloud), 아래는 이 Mac 만
struct FolderEditor: View {
    @EnvironmentObject private var folders: SyncFolderStore
    let folderID: String
    let onDelete: () -> Void
    @State private var name = ""

    private var setting: LocalFolderSetting { folders.setting(folderID) }

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
                    if let error = folders.iCloudError {
                        Text(error).foregroundStyle(.orange)
                    }
                }
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
                }
            } header: {
                Text("이 Mac (\(DeviceInfo.computerName))")
            } footer: {
                Text("이 설정은 이 Mac 에만 저장됩니다. 아직 파일은 주고받지 않습니다.")
            }

            Section {
                Button("폴더 삭제…", role: .destructive, action: onDelete)
            }
        }
        .formStyle(.grouped)
        .onAppear { name = folders.folder(folderID)?.name ?? "" }
        .onChange(of: folders.folder(folderID)?.name) { _, new in
            // 다른 Mac 에서 바꾼 이름이 들어오면 (내가 고치는 중이 아닐 때) 반영
            if let new, new != name { name = new }
        }
    }
}
