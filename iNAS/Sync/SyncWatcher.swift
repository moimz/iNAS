import CoreServices
import Foundation

/// 폴더 안 변경을 FSEvents 로 받아 상대 경로로 알린다 (1초 모아서)
final class SyncWatcher {
    private var stream: FSEventStreamRef?
    private let root: String
    /// 지켜보는 폴더 (처음 받은 경로)
    let path: String
    private let onChange: ([String]) -> Void

    init?(path: String, onChange: @escaping ([String]) -> Void) {
        self.path = path
        root = (path as NSString).standardizingPath
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<SyncWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.handle(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return nil }
        FSEventStreamSetDispatchQueue(s, DispatchQueue(label: "iNAS.sync.watch"))
        FSEventStreamStart(s)
        stream = s
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    private func handle(_ paths: [String]) {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var rel = Set<String>()
        for p in paths {
            let std = (p as NSString).standardizingPath
            if std == root { rel = [""]; break }
            guard std.hasPrefix(prefix) else { continue }
            let r = String(std.dropFirst(prefix.count))
            let base = (r as NSString).lastPathComponent
            if base.hasPrefix(SyncFolderIndex.tempPrefix) { continue }  // 받는 중인 임시 파일
            rel.insert(r)
        }
        if !rel.isEmpty { onChange(Array(rel)) }
    }
}
