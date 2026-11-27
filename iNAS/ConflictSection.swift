import AppKit
import SwiftUI

/// 폴더 화면의 "충돌 사본" 칸: 한눈에 보고 비교 · 사본으로 바꾸기 · 지우기.
/// 디스크 일은 앱 창이 직접 하고(휴지통으로), 에이전트가 바뀐 것을 알아채 다른 Mac 에도 맞춘다.
struct ConflictSection: View {
    let root: String
    let conflicts: [String]
    @State private var confirmAll = false
    @State private var error: String?

    /// "a/b/note.sync-conflict-20261128-003404-F4A54E0.txt" → 원본 이름 · 시각
    struct Item: Identifiable {
        let copy: String
        let original: String
        let date: Date?
        var id: String { copy }
    }

    private static let pattern = try! NSRegularExpression(pattern: #"\.sync-conflict-(\d{8})-(\d{6})-[0-9A-Fa-f]+"#)

    static func parse(_ name: String) -> Item {
        let range = NSRange(name.startIndex..., in: name)
        guard let m = pattern.firstMatch(in: name, range: range), let r = Range(m.range, in: name),
              let d = Range(m.range(at: 1), in: name), let t = Range(m.range(at: 2), in: name) else {
            return Item(copy: name, original: name, date: nil)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        return Item(copy: name, original: name.replacingCharacters(in: r, with: ""), date: f.date(from: String(name[d]) + String(name[t])))
    }

    private var items: [Item] { conflicts.map(Self.parse) }

    private func url(_ rel: String) -> URL { URL(fileURLWithPath: root).appendingPathComponent(rel) }

    var body: some View {
        Section {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.original).lineLimit(1).truncationMode(.middle)
                        Text("충돌 사본 · \(item.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "시각 모름")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("비교") { compare(item) }
                    Menu {
                        Button("Finder 에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([url(item.copy), url(item.original)]) }
                        Button("이 사본으로 바꾸기") { useCopy(item) }
                        Divider()
                        Button("사본 지우기", role: .destructive) { trash([item.copy]) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .help(item.copy)
            }
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        } header: {
            HStack {
                Text("충돌 사본 (\(conflicts.count))")
                Spacer()
                Button("모두 지우기…") { confirmAll = true }
            }
        } footer: {
            Text("양쪽 Mac 에서 같은 파일을 따로 고치면, 수정 시각이 늦은 쪽이 원래 이름이 되고 다른 쪽은 사본으로 남습니다. 비교해서 필요한 내용을 옮긴 뒤 사본을 지우세요. 지운 사본은 휴지통으로 가고, 다른 Mac 에서도 지워집니다.")
        }
        .confirmationDialog("충돌 사본 \(conflicts.count)개를 모두 지울까요?", isPresented: $confirmAll) {
            Button("모두 휴지통으로", role: .destructive) { trash(conflicts) }
        } message: {
            Text("이 Mac 에서는 휴지통으로 가고, 다른 Mac 에서도 지워집니다. 원래 파일은 그대로 둡니다.")
        }
    }

    /// FileMerge(opendiff)로 원본과 사본을 나란히. 없으면 Finder 에서 둘 다 보여 준다
    private func compare(_ item: Item) {
        let a = url(item.original).path, b = url(item.copy).path
        let tool = "/usr/bin/opendiff"
        if FileManager.default.isExecutableFile(atPath: tool), FileManager.default.fileExists(atPath: a) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = [a, b]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run(); return } catch {}
        }
        NSWorkspace.shared.activateFileViewerSelecting([url(item.copy), url(item.original)])
    }

    /// 원본을 휴지통으로 보내고 사본을 원래 이름으로
    private func useCopy(_ item: Item) {
        error = nil
        let fm = FileManager.default
        let orig = url(item.original), copy = url(item.copy)
        do {
            if fm.fileExists(atPath: orig.path) { try fm.trashItem(at: orig, resultingItemURL: nil) }
            try fm.moveItem(at: copy, to: orig)
        } catch {
            self.error = "바꾸지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func trash(_ names: [String]) {
        error = nil
        var failed = 0
        for n in names {
            do { try FileManager.default.trashItem(at: url(n), resultingItemURL: nil) } catch { failed += 1 }
        }
        if failed > 0 { error = "\(failed)개를 지우지 못했습니다." }
    }
}
