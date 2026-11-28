import AppKit
import SwiftUI

/// 일반 창 위에 설정 창 같은 툴바 탭(아이콘 + 이름, 고른 것 강조)을 단다.
/// SwiftUI TabView 가 툴바 탭이 되는 것은 Settings 장면뿐이라, 다른 창에서는 NSToolbar 고를 수 있는 항목으로 직접 만든다 (Ai.md 12번)
/// 쓰기: `.background(WindowToolbarTabs(tabs: [...], selection: $tab))`
struct WindowToolbarTabs: NSViewRepresentable {
	struct Tab {
		let title: String
		let symbol: String
	}

	let tabs: [Tab]
	@Binding var selection: Int

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> NSView {
		let v = WindowWatcher()
		v.onWindow = { [weak coordinator = context.coordinator] w in coordinator?.install(on: w) }
		return v
	}

	func updateNSView(_ v: NSView, context: Context) {
		context.coordinator.parent = self
		context.coordinator.syncSelection()
	}

	/// 창에 붙는 순간을 알려 주는 빈 뷰
	final class WindowWatcher: NSView {
		var onWindow: ((NSWindow) -> Void)?
		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if let w = window { DispatchQueue.main.async { self.onWindow?(w) } }
		}
	}

	final class Coordinator: NSObject, NSToolbarDelegate {
		var parent: WindowToolbarTabs
		private weak var toolbar: NSToolbar?

		init(_ p: WindowToolbarTabs) { parent = p }

		private func ident(_ i: Int) -> NSToolbarItem.Identifier { .init("tab.\(i)") }
		private var idents: [NSToolbarItem.Identifier] { parent.tabs.indices.map(ident) }

		func install(on window: NSWindow) {
			if let t = toolbar, window.toolbar === t { syncSelection(); return }
			let t = NSToolbar(identifier: "WindowToolbarTabs.\(UUID().uuidString)")
			t.delegate = self
			t.displayMode = .iconAndLabel
			t.allowsUserCustomization = false
			window.toolbar = t
			window.toolbarStyle = .preference
			toolbar = t
			syncSelection()
		}

		func syncSelection() {
			guard let t = toolbar else { return }
			let want = ident(min(max(parent.selection, 0), parent.tabs.count - 1))
			if t.selectedItemIdentifier != want { t.selectedItemIdentifier = want }
		}

		@objc private func choose(_ item: NSToolbarItem) {
			guard let i = idents.firstIndex(of: item.itemIdentifier) else { return }
			if parent.selection != i { parent.selection = i }
		}

		func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { idents }
		func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { idents }
		func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { idents }

		func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
			guard let i = idents.firstIndex(of: id) else { return nil }
			let tab = parent.tabs[i]
			let item = NSToolbarItem(itemIdentifier: id)
			item.label = tab.title
			item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
			item.target = self
			item.action = #selector(choose(_:))
			return item
		}
	}
}
