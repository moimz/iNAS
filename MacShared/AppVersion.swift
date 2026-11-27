import Foundation

/// "2.4 (빌드 45 · 1231858)" (Ai.md "앱 안의 버전 표시"). 해시는 빌드 단계 Scripts/stamp-commit.sh 가 본체 Info.plist 의 INASCommit 에 넣는다.
/// 에이전트(iNAS.app/Contents/Library/LoginItems/iNASAgent.app)에서 부르면 본체 Info.plist 를 읽는다.
enum AppVersion {
    static var mainBundle: Bundle {
        guard Bundle.main.bundleIdentifier == "com.moimz.iNAS.agent" else { return .main }
        var url = Bundle.main.bundleURL
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return Bundle(url: url) ?? .main
    }

    static var text: String {
        let info = mainBundle.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        let c = (info?["INASCommit"] as? String).map { " · \($0)" } ?? ""
        return "\(v) (빌드 \(b)\(c))"
    }
}
