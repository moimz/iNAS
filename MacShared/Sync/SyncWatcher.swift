import CoreServices
import Foundation

/// 폴더 안 변경을 FSEvents 로 받아 상대 경로로 알린다 (1초 모아서)
final class SyncWatcher {
    private var stream: FSEventStreamRef?
    private let root: String
    /// 받은 경로 · 실제 경로 앞부분 (SyncFolderIndex.pathPrefixes)
    private let prefixes: [String]
    /// 지켜보는 폴더 (처음 받은 경로)
    let path: String
    private let onChange: ([String]) -> Void

    init?(path: String, onChange: @escaping ([String]) -> Void) {
        self.path = path
        root = (path as NSString).standardizingPath
        prefixes = SyncFolderIndex.pathPrefixes(path)
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
        var rel = Set<String>()
        for p in paths {
            let std = (p as NSString).standardizingPath
            // 폴더가 심볼릭 링크면 FSEvents 는 링크를 푼 실제 경로로 알려 준다
            if prefixes.contains(std + "/") || prefixes.contains(p + "/") { rel = [""]; break }
            guard let prefix = prefixes.first(where: { p.hasPrefix($0) || std.hasPrefix($0) }) else { continue }
            let r = String((p.hasPrefix(prefix) ? p : std).dropFirst(prefix.count))
            let base = (r as NSString).lastPathComponent
            if base.hasPrefix(SyncFolderIndex.tempPrefix) { continue }  // 받는 중인 임시 파일
            rel.insert(r)
        }
        if !rel.isEmpty { onChange(Array(rel)) }
    }
}
