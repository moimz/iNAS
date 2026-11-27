import CryptoKit
import Darwin
import Foundation

/// 폴더 하나의 이 기기 파일 목록 · 다른 기기 목록 · 디스크 훑기 · 디스크에 쓰기.
/// SyncEngine 안에서만(한 번에 하나씩) 쓴다.
final class SyncFolderIndex {
    /// 폴더 맨 위의 표시 파일. 이게 없으면 폴더를 멈춘다(디스크가 안 붙어 비어 보일 때 "다 지워짐" 을 퍼뜨리지 않게, Syncthing .stfolder)
    static let markerName = ".inasfolder"
    /// 받는 중인 임시 파일 접두어 (Syncthing .syncthing.이름.tmp)
    static let tempPrefix = ".inas-tmp."

    struct LocalMeta: Codable, Equatable {
        var inode: UInt64
        /// 디스크의 실제 이름 (NFC/NFD 가 다를 수 있음)
        var diskName: String
    }

    private struct Saved: Codable {
        var files: [String: SyncFile]
        var meta: [String: LocalMeta]
        var sequence: Int64
    }

    private(set) var config: SyncFolderConfig
    let me: ShortID
    private let stateURL: URL
    private(set) var ignore: SyncIgnore

    /// 이 기기 목록 (NFC 이름 → 항목)
    private(set) var files: [String: SyncFile] = [:]
    private(set) var meta: [String: LocalMeta] = [:]
    private(set) var sequence: Int64 = 0
    /// 다른 기기 목록 (기기 아이디 → 이름 → 항목). 연결될 때 통째로 다시 받는다
    var remote: [String: [String: SyncFile]] = [:]
    /// 마지막 오류 (폴더가 멈춘 이유)
    private(set) var stopReason: String?

    var root: URL { URL(fileURLWithPath: config.path, isDirectory: true) }

    init(config: SyncFolderConfig, me: ShortID, stateDir: URL) {
        self.config = config
        self.me = me
        self.ignore = SyncIgnore(config.ignores)
        stateURL = stateDir.appendingPathComponent("folder-\(config.id).plist")
        if let data = try? Data(contentsOf: stateURL), let s = try? PropertyListDecoder().decode(Saved.self, from: data) {
            files = s.files
            meta = s.meta
            sequence = s.sequence
        }
    }

    func update(config c: SyncFolderConfig) {
        if c.ignores != config.ignores { ignore = SyncIgnore(c.ignores) }
        config = c
    }

    func save() {
        guard let data = try? PropertyListEncoder().encode(Saved(files: files, meta: meta, sequence: sequence)) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: 폴더 확인

    /// 폴더가 있고 표시 파일이 있는지. 처음(목록이 비었을 때)이면 표시 파일을 만든다
    func checkFolder() -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            stopReason = "폴더가 없습니다: \(config.path)"
            return false
        }
        let marker = root.appendingPathComponent(Self.markerName)
        if !FileManager.default.fileExists(atPath: marker.path) {
            if files.isEmpty {
                FileManager.default.createFile(atPath: marker.path, contents: Data("iNAS 동기화 폴더 표시 — 지우지 마세요\n".utf8))
            } else {
                stopReason = "폴더 표시 파일(\(Self.markerName))이 없어 멈췄습니다. 디스크가 빠졌거나 폴더가 바뀌었을 수 있습니다."
                return false
            }
        }
        stopReason = nil
        return true
    }

    static func isInternal(_ name: String) -> Bool {
        let base = name.split(separator: "/").last.map(String.init) ?? name
        return name == markerName || base.hasPrefix(tempPrefix)
    }

    func isIgnored(_ name: String) -> Bool { Self.isInternal(name) || ignore.isIgnored(name) }

    // MARK: 훑기

    private struct Stat {
        var kind: SyncFile.Kind
        var size: Int64
        var modified: Int64
        var permissions: UInt32
        var inode: UInt64
        var target: String?
    }

    private func stat(_ url: URL) -> Stat? {
        var st = Darwin.stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let mode = st.st_mode & S_IFMT
        let kind: SyncFile.Kind
        var target: String?
        switch mode {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .file
        case S_IFLNK:
            kind = .symlink
            target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        default: return nil
        }
        let ns = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        return Stat(kind: kind, size: kind == .file ? Int64(st.st_size) : 0, modified: ns,
                    permissions: UInt32(st.st_mode & 0o777), inode: UInt64(st.st_ino), target: target)
    }

    /// 목록과 디스크가 같은지 (크기 · 수정 시각 · inode · 권한)
    private func unchanged(_ name: String, _ s: Stat) -> Bool {
        guard let f = files[name], !f.deleted, f.kind == s.kind else { return false }
        switch s.kind {
        case .directory: return f.permissions == s.permissions
        case .symlink: return f.symlinkTarget == s.target
        case .file:
            return f.size == s.size && f.modified == s.modified && f.permissions == s.permissions && meta[name]?.inode == s.inode
        }
    }

    /// 디스크를 훑어 바뀐 항목을 목록에 넣고 돌려준다. subpaths 가 있으면 그 아래만(지움도 그 아래만).
    func scan(subpaths: [String]? = nil) -> [SyncFile] {
        guard checkFolder() else { return [] }
        var changed: [SyncFile] = []
        var seen = Set<String>()

        func visit(_ rel: String) -> Bool {  // true 면 그 아래로 내려간다 (폴더일 때만)
            let name = rel.precomposedStringWithCanonicalMapping
            if Self.isInternal(name) { return false }
            if ignore.matchSelf(name).ignored { return false }
            let url = root.appendingPathComponent(rel)
            guard let s = stat(url) else { return false }
            seen.insert(name)
            if !unchanged(name, s), let f = makeFile(name: name, diskName: rel, url: url, stat: s) {
                changed.append(f)
            }
            return s.kind == .directory
        }

        func walk(_ rel: String) {
            let base = rel.isEmpty ? root : root.appendingPathComponent(rel)
            guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil, options: [],
                                                          errorHandler: { _, _ in true }) else { return }
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            for case let url as URL in e {
                let full = url.path
                guard full.hasPrefix(rootPath) else { continue }
                let r = String(full.dropFirst(rootPath.count))
                // skipDescendants 는 폴더에서만 부른다: 파일에서 부르면 그 폴더의 나머지 형제까지 건너뛴다
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
                    .map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
                if !visit(r), isDir { e.skipDescendants() }
            }
        }

        let scopes = subpaths ?? [""]
        for scope in scopes {
            if scope.isEmpty {
                walk("")
            } else {
                // 위 폴더들도 목록에 있게 하고, 마지막이 폴더면 그 아래를 훑는다
                let parts = scope.split(separator: "/").map(String.init)
                for i in 1...parts.count {
                    let p = parts[0..<i].joined(separator: "/")
                    guard FileManager.default.fileExists(atPath: root.appendingPathComponent(p).path) else { break }
                    let descend = visit(p)
                    if i == parts.count {
                        if descend { walk(p) }
                    } else if !descend {
                        break
                    }
                }
            }
        }

        // 지워진 것: 목록에 있는데 안 보임 (예외가 된 것은 그대로 둔다)
        let now = Int64(Date().timeIntervalSince1970 * 1e9)
        for (name, f) in files where !f.deleted && !seen.contains(name) {
            if let sub = subpaths, !sub.contains(where: { $0.isEmpty || name == $0.precomposedStringWithCanonicalMapping || name.hasPrefix($0.precomposedStringWithCanonicalMapping + "/") }) { continue }
            if isIgnored(name) { continue }
            sequence += 1
            var d = f
            d.deleted = true
            d.version = f.version.updated(me)
            d.modified = now
            d.size = 0
            d.blocks = []
            d.previousBlocksHash = f.blocksHash
            d.blocksHash = nil
            d.modifiedBy = me
            d.sequence = sequence
            d.symlinkTarget = nil
            files[name] = d
            meta[name] = nil
            changed.append(d)
        }
        if !changed.isEmpty { save() }
        return changed
    }

    private func makeFile(name: String, diskName: String, url: URL, stat s: Stat) -> SyncFile? {
        var blocks: [SyncBlock] = []
        var blocksHash: Data?
        if s.kind == .file {
            guard let b = Self.hashBlocks(url, size: s.size) else { return nil }
            // 읽는 동안 바뀌었으면 다음에
            guard let again = stat(url), again.size == s.size, again.modified == s.modified else { return nil }
            blocks = b
            blocksHash = SyncFile.hashOfBlocks(b)
        }
        let old = files[name]
        // 내용 · 종류 · 권한 · 수정 시각이 그대로면(inode 만 바뀜) 버전을 올리지 않고 기록만 맞춘다
        if let old, !old.deleted, old.kind == s.kind, old.permissions == s.permissions, old.symlinkTarget == s.target,
           s.kind != .file || (old.blocksHash == blocksHash && old.size == s.size && old.modified == s.modified) {
            meta[name] = LocalMeta(inode: s.inode, diskName: diskName)
            return nil
        }
        sequence += 1
        let f = SyncFile(
            name: name, kind: s.kind, size: s.size, modified: s.modified, permissions: s.permissions, deleted: false,
            version: (old?.version ?? SyncVector()).updated(me), sequence: sequence, blocks: blocks, blocksHash: blocksHash,
            previousBlocksHash: old?.blocksHash, modifiedBy: me, symlinkTarget: s.target
        )
        files[name] = f
        meta[name] = LocalMeta(inode: s.inode, diskName: diskName)
        return f
    }

    static func hashBlocks(_ url: URL, size: Int64) -> [SyncBlock]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let bs = SyncFile.blockSize(for: size)
        var blocks: [SyncBlock] = []
        var offset: Int64 = 0
        while true {
            // 파일 끝이면 nil 이 온다(빈 Data 가 아님)
            let chunk: Data
            do { chunk = try h.read(upToCount: bs) ?? Data() } catch { return nil }
            if chunk.isEmpty { break }
            blocks.append(SyncBlock(offset: offset, size: Int32(chunk.count), hash: Data(SHA256.hash(data: chunk))))
            offset += Int64(chunk.count)
            if chunk.count < bs { break }
        }
        return blocks
    }

    // MARK: 전역 버전 · 받을 것

    /// 이 이름의 가장 좋은 버전과 그것을 가진 기기(nil = 나)
    func global(_ name: String) -> (file: SyncFile, from: String?)? {
        var best: (SyncFile, String?)? = files[name].map { ($0, nil) }
        for (dev, list) in remote {
            guard let f = list[name] else { continue }
            if let b = best {
                if f.isBetter(than: b.0) { best = (f, dev) }
            } else {
                best = (f, dev)
            }
        }
        return best
    }

    /// 받아야 할 것: 전역 버전이 다른 기기 것이고 내 것과 버전이 다를 때 (지움인데 나도 없으면 빼고)
    func needed() -> [(file: SyncFile, from: String)] {
        var names = Set<String>()
        for list in remote.values { names.formUnion(list.keys) }
        var out: [(SyncFile, String)] = []
        for name in names {
            guard let g = global(name), let from = g.from else { continue }
            if isIgnored(name) { continue }
            let local = files[name]
            if let local, local.version == g.file.version { continue }
            if g.file.deleted && (local == nil || local!.deleted) {
                // 나도 없는데 지움만 다름: 목록만 맞춘다(디스크 할 일 없음)
                adoptWithoutDisk(g.file)
                continue
            }
            out.append((g.file, from))
        }
        // 폴더 먼저(얕은 것부터), 그다음 파일, 지움은 맨 끝(깊은 것부터) — Syncthing 순서
        return out.sorted { a, b in
            func rank(_ f: SyncFile) -> Int { f.deleted ? 2 : (f.kind == .directory ? 0 : 1) }
            let ra = rank(a.0), rb = rank(b.0)
            if ra != rb { return ra < rb }
            let da = a.0.name.split(separator: "/").count, db = b.0.name.split(separator: "/").count
            if ra == 2 { return da > db }
            if da != db { return da < db }
            return a.0.name < b.0.name
        }
    }

    /// 디스크 일 없이 목록만 전역 버전으로 (지움끼리 등)
    private func adoptWithoutDisk(_ g: SyncFile) {
        guard files[g.name]?.version != g.version else { return }
        sequence += 1
        var f = g
        f.sequence = sequence
        files[g.name] = f
    }

    // MARK: 디스크에 쓰기 (받기)

    func url(of name: String) -> URL {
        root.appendingPathComponent(meta[name]?.diskName ?? name.decomposedStringWithCanonicalMapping)
    }

    /// 디스크가 목록과 다른가 (아직 안 훑은 내 쪽 변경). 다르면 받지 말고 다시 훑어야 한다 (Syncthing scanIfItemChanged)
    func diskDiffers(_ name: String) -> Bool {
        let u = url(of: name)
        let s = stat(u)
        guard let f = files[name], !f.deleted else { return s != nil }
        guard let s else { return true }
        return !unchanged(name, s)
    }

    /// 받은 것을 목록에 넣는다 (버전은 받은 그대로, 순번만 내 것)
    func record(_ g: SyncFile, diskName: String?) {
        sequence += 1
        var f = g
        f.sequence = sequence
        files[g.name] = f
        if g.deleted {
            meta[g.name] = nil
        } else if let diskName, let s = stat(root.appendingPathComponent(diskName)) {
            meta[g.name] = LocalMeta(inode: s.inode, diskName: diskName)
        }
    }

    /// 충돌 사본 이름: 이름.sync-conflict-YYYYMMDD-HHMMSS-기기.확장자 (Syncthing conflictName)
    static func conflictName(_ name: String, by: ShortID) -> String {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let short = String(format: "%016llX", by).prefix(7)
        return base + ".sync-conflict-" + f.string(from: Date()) + "-" + short + (ext.isEmpty ? "" : "." + ext)
    }

    static func isConflict(_ name: String) -> Bool {
        (name.split(separator: "/").last ?? "").contains(".sync-conflict-")
    }

    static let maxConflicts = 10

    /// 내 파일을 충돌 사본으로 옮긴다 (지우지 않는다). 충돌 사본에 또 충돌이면 사본을 더 만들지 않는다
    /// 돌려주는 값: 새로 생긴 사본의 디스크 상대 경로 (훑어서 목록에 넣을 것)
    func moveForConflict(_ name: String, by: ShortID) throws -> String? {
        let u = url(of: name)
        if Self.isConflict(name) {
            try? FileManager.default.removeItem(at: u)
            return nil
        }
        let disk = meta[name]?.diskName ?? name.decomposedStringWithCanonicalMapping
        let newDisk = Self.conflictName(disk, by: by)
        do {
            try FileManager.default.moveItem(at: u, to: root.appendingPathComponent(newDisk))
        } catch CocoaError.fileNoSuchFile {
            return nil
        }
        // 파일당 사본은 10개까지, 넘으면 오래된 것부터 지운다
        let dir = (newDisk as NSString).deletingLastPathComponent
        let fileBase = ((disk as NSString).lastPathComponent as NSString).deletingPathExtension
        let dirURL = dir.isEmpty ? root : root.appendingPathComponent(dir)
        if let list = try? FileManager.default.contentsOfDirectory(atPath: dirURL.path) {
            let copies = list.filter { $0.hasPrefix(fileBase + ".sync-conflict-") }.sorted(by: >)
            for old in copies.dropFirst(Self.maxConflicts) {
                try? FileManager.default.removeItem(at: dirURL.appendingPathComponent(old))
            }
        }
        return newDisk
    }
}
