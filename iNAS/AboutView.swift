import AppKit
import SwiftUI

/// iNAS 정보 창 (메뉴 iNAS > iNAS에 관하여). iSQL 정보 창과 같은 모양: 아이콘·이름·버전, 그 아래 오픈소스 고지 상자.
/// macOS 기본 정보 창은 글 영역에 여백·둥근 상자를 줄 수 없어 직접 만든다. 저작권 줄(©)은 두지 않는다 (사용자 2026-11-26)
struct AboutView: View {
    static let windowID = "about"

    /// "2.3.1 (빌드 44 · 5eea4ef)" (Ai.md "앱 안의 버전 표시"). 해시는 빌드 단계 Scripts/stamp-commit.sh 가 INASCommit 에 넣는다
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        let c = (info?["INASCommit"] as? String).map { " · \($0)" } ?? ""
        return "\(v) (빌드 \(b)\(c))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.top, 8)
            Text("iNAS").font(.title2.bold()).padding(.top, 10)
            Text("버전 " + Self.versionText).font(.callout).foregroundStyle(.secondary).padding(.top, 4)

            VStack(alignment: .leading, spacing: 12) {
                section("오픈소스") {
                    item("Sparkle (MIT)", "자동 업데이트")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.top, 18)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(width: 360)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.semibold).foregroundStyle(.primary.opacity(0.75))
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func item(_ name: String, _ what: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("·")
            Text(name) + Text(" — " + what).foregroundStyle(.tertiary)
        }
    }
}

/// 메뉴 iNAS > iNAS에 관하여 (기본 정보 창 대신 AboutView)
struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("iNAS에 관하여") { openWindow(id: AboutView.windowID) }
    }
}
