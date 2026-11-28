import SwiftUI

extension SyncDevice {
    /// 기기 종류 → SF 기호 (설정 › 동기화 · 폴더 화면 칸 제목)
    var symbolName: String {
        let m = model + " " + modelID
        if m.contains("MacBook") { return "macbook" }
        if m.contains("Mac mini") { return "macmini" }
        if m.contains("Mac Studio") { return "macstudio" }
        if m.contains("Mac Pro") { return "macpro.gen3" }
        if m.contains("iPhone") { return "iphone" }
        if m.contains("iPad") { return "ipad" }
        return "desktopcomputer"
    }
}

/// 기기 칸 제목: [기기 아이콘] 이름 (이 기기)
struct DeviceSectionTitle: View {
    let symbol: String
    let name: String
    var isMe = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(name)
            if isMe { Text("(이 기기)").foregroundStyle(.secondary) }
        }
    }
}

/// 동기화 상태 기호: 맞춰짐 초록 원 · 맞추는 중 돌아가는 동기화 아이콘 · 문제 주황 · 연결 안 됨 빨간 원 · 기다림 회색 원
struct SyncStateSymbol: View {
    enum Kind { case synced, syncing, problem, offline, waiting }
    let kind: Kind

    var body: some View {
        switch kind {
        case .synced: Circle().fill(Color.green).frame(width: 8, height: 8)
        case .offline: Circle().fill(Color.red).frame(width: 8, height: 8)
        case .waiting: Circle().fill(Color.gray).frame(width: 8, height: 8)
        case .syncing:
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.rotate, options: .repeat(.continuous))
        case .problem:
            Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(Color.orange)
        }
    }
}

/// "상태" 줄: [기호] 글 · 파일 수 [상세보기]
struct FolderStatusLine: View {
    let folderID: String
    /// 다른 Mac 칸이면 그 기기 키 아이디 (상세 창이 그 Mac 에 달라고 한다)
    var peer: String? = nil
    let kind: SyncStateSymbol.Kind
    let text: String
    let count: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        LabeledContent("상태") {
            HStack(spacing: 8) {
                SyncStateSymbol(kind: kind)
                // 글 옆에 버튼을 두면 글이 잘리고 버튼 옆이 빈다 → lineLimit + fixedSize (Ai.md 12번)
                Text(text).lineLimit(1).fixedSize()
                if let count {
                    Text(count).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
                }
                // 별도 창 (시트는 macOS 26 에서 창 가운데 떠서, 사용자 2026-11-28)
                Button("상세보기") { openWindow(id: "folderDetail", value: FolderDetailTarget(folderID: folderID, peer: peer)) }
            }
        }
    }

    static func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    static func count(files: Int, bytes: Int64) -> String { "\(files.formatted())개 · \(size(bytes))" }
}
