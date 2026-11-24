import FileProvider
import SwiftUI

/// 진행률 시험용 앱: 파일 앱에 "iNAS 시험" 위치를 등록하고, 올리기 시험용 큰 파일을 Documents 에 만든다.
@main
struct FPTestApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var status = "준비 중…"

    var body: some View {
        VStack(spacing: 16) {
            Text("iNAS 파일 앱 진행률 시험").font(.headline)
            Text(status).font(.footnote).multilineTextAlignment(.center)
            Button("위치 다시 등록 (받아 둔 파일 지움)") { reset() }
        }
        .padding()
        .task { setup() }
    }

    private var domain: NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("test"), displayName: "iNAS 시험")
    }

    private func setup() {
        makeUploadFile()
        NSFileProviderManager.add(domain) { error in
            Task { @MainActor in
                status = error.map { "위치 등록 실패: \($0.localizedDescription)" } ?? "파일 앱에 \"iNAS 시험\" 위치를 등록했습니다.\n올리기 시험 파일: 나의 iPhone › iNAS 시험 › 올리기-300MB.bin"
            }
        }
    }

    private func reset() {
        NSFileProviderManager.remove(domain) { _ in
            Task { @MainActor in setup() }
        }
    }

    /// 올리기 시험용 300MB 파일 (앱 Documents → 파일 앱 "나의 iPhone")
    private func makeUploadFile() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("올리기-300MB.bin")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        let block = Data(count: 1024 * 1024)
        for _ in 0..<300 { handle.write(block) }
        try? handle.close()
    }
}
