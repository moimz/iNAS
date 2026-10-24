import Darwin
import Foundation
import NetFS
import Network

enum ShareOutcome: Hashable {
    case mounted(path: String)
    case alreadyMounted(path: String)
    case failed(message: String)

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct ShareResult: Hashable, Identifiable {
    var share: String
    var outcome: ShareOutcome
    var id: String { share }
}

struct ServerResult: Hashable, Identifiable {
    enum State: Hashable {
        case done
        case unreachable
        case missingPassword
        case nothingSelected
    }

    var serverID: UUID
    var serverName: String
    var state: State
    var shares: [ShareResult] = []
    var id: UUID { serverID }

    var newlyMounted: Int {
        shares.filter { if case .mounted = $0.outcome { return true } else { return false } }.count
    }
    var failures: Int { shares.filter { $0.outcome.isFailure }.count }
}

enum Mounter {
    static func mountAll(_ servers: [ServerConfig], attempts: Int, retryDelay: TimeInterval) async -> [ServerResult] {
        await withTaskGroup(of: (Int, ServerResult).self) { group in
            for (i, server) in servers.enumerated() {
                group.addTask { (i, await mount(server, attempts: attempts, retryDelay: retryDelay)) }
            }
            var results: [(Int, ServerResult)] = []
            for await r in group { results.append(r) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func mount(_ server: ServerConfig, attempts: Int, retryDelay: TimeInterval) async -> ServerResult {
        var result = ServerResult(serverID: server.id, serverName: server.displayName, state: .done)
        guard !server.shares.isEmpty, !server.host.isEmpty else {
            result.state = .nothingSelected
            return result
        }

        var reachable = false
        for attempt in 1...max(1, attempts) {
            if await isReachable(host: server.host, port: server.port ?? 445, timeout: 4) {
                reachable = true
                break
            }
            Log.mount.info("\(server.host, privacy: .public) 응답 없음 (\(attempt)/\(attempts))")
            if attempt < attempts {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
        }
        guard reachable else {
            Log.mount.info("\(server.host, privacy: .public): 응답이 없어 건너뜁니다.")
            result.state = .unreachable
            return result
        }

        guard let password = Keychain.password(for: server.credentialKey) else {
            Log.mount.info("\(server.host, privacy: .public): 키체인에 비밀번호가 없습니다.")
            result.state = .missingPassword
            return result
        }

        let existing = MountTable.smbMounts()
        for share in server.shares {
            if let m = existing.first(where: { $0.matches(host: server.host, share: share) }) {
                result.shares.append(ShareResult(share: share, outcome: .alreadyMounted(path: m.mountPoint)))
                continue
            }
            let outcome = await mountShare(share, on: server, password: password)
            Log.mount.info("\(server.host, privacy: .public)/\(share, privacy: .public): \(String(describing: outcome), privacy: .public)")
            result.shares.append(ShareResult(share: share, outcome: outcome))
        }
        return result
    }

    // MARK: NetFS

    private static func mountShare(_ share: String, on server: ServerConfig, password: String) async -> ShareOutcome {
        var components = URLComponents()
        components.scheme = "smb"
        components.host = server.host
        components.port = server.port
        components.path = "/" + share
        guard let url = components.url else {
            return .failed(message: "공유 주소를 만들 수 없습니다.")
        }

        return await withCheckedContinuation { continuation in
            // 인증 창 등 UI를 띄우지 않는다.
            let openOptions = NSMutableDictionary(dictionary: ["UIOption": "NoUI"])
            let mountOptions = NSMutableDictionary()
            var requestID: AsyncRequestID?
            let status = NetFSMountURLAsync(
                url as CFURL,
                nil,
                server.username as CFString,
                password as CFString,
                openOptions,
                mountOptions,
                &requestID,
                DispatchQueue.global(qos: .userInitiated)
            ) { status, _, mountpoints in
                if status == 0 {
                    let paths = (mountpoints as? [Any])?.compactMap { item -> String? in
                        if let s = item as? String { return s }
                        if let u = item as? URL { return u.path }
                        return nil
                    } ?? []
                    continuation.resume(returning: .mounted(path: paths.first ?? "/Volumes/\(share)"))
                } else if status == EEXIST {
                    continuation.resume(returning: .alreadyMounted(path: "/Volumes/\(share)"))
                } else {
                    continuation.resume(returning: .failed(message: describe(status)))
                }
            }
            if status != 0 {
                continuation.resume(returning: .failed(message: describe(status)))
            }
        }
    }

    private static func describe(_ status: Int32) -> String {
        switch status {
        case EAUTH, EACCES, EPERM: return "아이디나 비밀번호가 맞지 않거나 권한이 없습니다. (코드 \(status))"
        case ENOENT: return "서버에 이런 이름의 공유가 없습니다."
        case ETIMEDOUT, EHOSTUNREACH, ENETUNREACH, ECONNREFUSED: return "서버에 연결하지 못했습니다."
        case ECANCELED, -128: return "연결이 취소되었습니다."
        default:
            return "연결 실패: \(String(cString: strerror(status))) (\(status))"
        }
    }

    // MARK: 접속 가능 여부

    static func isReachable(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation: continuation, connection: connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(true)
                case .failed, .waiting: once.finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.finish(false) }
        }
    }
}

/// 연결 확인 결과를 한 번만 돌려준다.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private let connection: NWConnection

    init(continuation: CheckedContinuation<Bool, Never>, connection: NWConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func finish(_ value: Bool) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return }
        connection.cancel()
        c.resume(returning: value)
    }
}

/// 현재 연결된 SMB 볼륨 목록 (getmntinfo).
enum MountTable {
    struct Entry {
        var host: String
        var share: String
        var mountPoint: String

        func matches(host otherHost: String, share otherShare: String) -> Bool {
            host.caseInsensitiveCompare(otherHost) == .orderedSame
                && share.caseInsensitiveCompare(otherShare) == .orderedSame
        }
    }

    static func smbMounts() -> [Entry] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        var entries: [Entry] = []
        for i in 0..<Int(count) {
            var fs = buffer[i]
            let type = withUnsafeBytes(of: &fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard type == "smbfs" else { continue }
            let from = withUnsafeBytes(of: &fs.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let onto = withUnsafeBytes(of: &fs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if let entry = parse(from: from, mountPoint: onto) { entries.append(entry) }
        }
        return entries
    }

    /// `//user@host:port/share` 형식을 나눈다.
    static func parse(from: String, mountPoint: String) -> Entry? {
        guard from.hasPrefix("//") else { return nil }
        let rest = from.dropFirst(2)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        var authority = String(rest[..<slash])
        let path = String(rest[rest.index(after: slash)...])
        if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
        if let colon = authority.lastIndex(of: ":") { authority = String(authority[..<colon]) }
        let share = (path.removingPercentEncoding ?? path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return Entry(host: authority, share: share, mountPoint: mountPoint)
    }
}
