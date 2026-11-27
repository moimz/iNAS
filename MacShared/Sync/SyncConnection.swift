import CryptoKit
import Foundation
import Network

// 기기 사이 연결: TLS 1.2 ECDHE-PSK (CHACHA20-POLY1305). 미리 나눈 키 = 두 기기 키의 ECDH (SyncIdentity.pairKey).
// 연결마다 임시 키를 섞어(ECDHE) 키가 나중에 새도 지난 통신은 못 푼다. 틀린 키면 손잡기에서 끊긴다.
// (TLS 1.3 외부 PSK 는 Network.framework 에서 손잡기가 실패해서 못 씀, 2026-11-27 시험)
enum SyncTLS {
    static let suite: UInt16 = 0xCCAC  // TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256

    private static func dispatchData(_ d: Data) -> __DispatchData {
        d.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }

    private static func options() -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let o = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(o, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(o, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(o, tls_ciphersuite_t(rawValue: suite)!)
        return tls
    }

    private static func tcp() -> NWProtocolTCP.Options {
        let t = NWProtocolTCP.Options()
        t.connectionTimeout = 8
        t.enableKeepalive = true
        t.keepaliveIdle = 30
        t.noDelay = true
        return t
    }

    /// 붙는 쪽: 내 아이디로 저쪽과의 키를 낸다
    static func clientParameters(me: SyncIdentity, peer: SyncPeer) throws -> NWParameters {
        let tls = options()
        let key = try me.pairKey(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.publicKey))
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                                                dispatchData(key.withUnsafeBytes { Data($0) }),
                                                dispatchData(Data(me.keyID.utf8)))
        return NWParameters(tls: tls, tcp: tcp())
    }

    /// 기다리는 쪽: 아는 기기마다 (그 기기 아이디 → 그 기기와의 키). 기기 목록이 바뀌면 대기를 다시 연다
    static func serverParameters(me: SyncIdentity, peers: [SyncPeer]) -> NWParameters {
        let tls = options()
        for p in peers {
            guard let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: p.publicKey),
                  let key = try? me.pairKey(with: pub) else { continue }
            sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                                                    dispatchData(key.withUnsafeBytes { Data($0) }),
                                                    dispatchData(Data(p.keyID.utf8)))
        }
        let params = NWParameters(tls: tls, tcp: tcp())
        params.allowLocalEndpointReuse = true
        return params
    }

    /// 인사 증명: 두 기기 키로 만든 HMAC (TLS 키를 가진 다른 기기가 이름을 속이지 못하게)
    static func helloProof(me: SyncIdentity, peer: SyncPeer, from: String, to: String) -> Data? {
        guard let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.publicKey),
              let key = try? me.pairKey(with: pub) else { return nil }
        return Data(HMAC<SHA256>.authenticationCode(for: Data("iNAS-hello|\(from)|\(to)".utf8), using: key))
    }
}

/// 주고받는 말
enum SyncMessage: Codable {
    struct Hello: Codable {
        var keyID: String
        var name: String
        var proof: Data
        /// 이 기기에서 켜진 폴더 아이디
        var folders: [String]
    }

    struct Index: Codable {
        var folder: String
        var files: [SyncFile]
        /// true 면 이 기기 목록을 비우고 새로 (연결 때 전체 목록의 첫 조각)
        var reset: Bool
    }

    struct Request: Codable {
        var id: Int
        var folder: String
        var name: String
        var offset: Int64
        var size: Int32
        var hash: Data
    }

    struct Response: Codable {
        var id: Int
        var data: Data?
        var error: String?
    }

    case hello(Hello)
    case index(Index)
    case request(Request)
    case response(Response)
    case folders([String])
    case ping
    case pong
}

/// 길이(4바이트) + 표시(1바이트, 1 = lzfse 압축) + binary plist
final class FrameConnection: @unchecked Sendable {
    static let maxFrame = 64 << 20

    let conn: NWConnection
    let queue: DispatchQueue
    let remote: String
    var onReady: (() -> Void)?
    var onMessage: ((SyncMessage) -> Void)?
    var onClose: ((String?) -> Void)?
    private var closed = false
    private let lock = NSLock()

    init(_ conn: NWConnection, queue: DispatchQueue) {
        self.conn = conn
        self.queue = queue
        if case .hostPort(let host, let port) = conn.endpoint { remote = "\(host):\(port)" } else { remote = "\(conn.endpoint)" }
    }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.readFrame()
            case .failed(let e), .waiting(let e): self.close(Self.describe(e))
            case .cancelled: self.close(nil)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    /// 실패 이유 앞에 붙는 말: 저쪽에 아예 닿지 않았는지(길이 막힘), 닿았는데 암호화 손잡기에서 끊겼는지(키 · 버전이 다름)
    static let unreachablePrefix = "연결 안 됨: "
    static let handshakePrefix = "암호화 손잡기 실패: "

    static func describe(_ e: NWError) -> String {
        switch e {
        case .tls: return handshakePrefix + e.localizedDescription
        default: return unreachablePrefix + e.localizedDescription
        }
    }

    /// 이 실패가 "길이 막힘" 인지 (닿았는데 손잡기 · 인사에서 끊긴 것은 아님). 옛 빌드 기록의 시간 초과도 막힘으로 본다
    static func isUnreachable(_ reason: String?) -> Bool {
        guard let r = reason else { return false }
        if r.hasPrefix(unreachablePrefix) { return true }
        if r.hasPrefix(handshakePrefix) { return false }
        return r.contains("timed out") || r.contains("시간 초과") || r.contains("Connection refused") || r.contains("No route to host")
    }

    func send(_ m: SyncMessage) {
        guard !isClosed else { return }
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        guard var body = try? enc.encode(m) else { return }
        var flag: UInt8 = 0
        if body.count > 1024, let c = try? (body as NSData).compressed(using: .lzfse) as Data, c.count < body.count {
            body = c
            flag = 1
        }
        var frame = Data(count: 5)
        let len = UInt32(body.count + 1).bigEndian
        withUnsafeBytes(of: len) { frame.replaceSubrange(0..<4, with: $0) }
        frame[4] = flag
        frame.append(body)
        conn.send(content: frame, completion: .contentProcessed { [weak self] e in
            if let e { self?.close(e.localizedDescription) }
        })
    }

    func close(_ reason: String?) {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        conn.cancel()
        let cb = onClose
        onReady = nil; onMessage = nil; onClose = nil
        cb?(reason)
    }

    private func readFrame() {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, complete, error in
            guard let self, !self.isClosed else { return }
            guard let data, data.count == 4 else {
                return self.close(error?.localizedDescription ?? (complete ? "저쪽이 끊음" : "읽기 실패"))
            }
            let len = Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
            guard len >= 1, len <= Self.maxFrame else { return self.close("틀린 길이 \(len)") }
            self.conn.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] body, _, complete, error in
                guard let self, !self.isClosed else { return }
                guard let body, body.count == len else {
                    return self.close(error?.localizedDescription ?? (complete ? "저쪽이 끊음" : "읽기 실패"))
                }
                var payload = body.dropFirst()
                if body.first == 1 {
                    guard let d = try? (Data(payload) as NSData).decompressed(using: .lzfse) as Data else { return self.close("압축 풀기 실패") }
                    payload = d[...]
                }
                guard let m = try? PropertyListDecoder().decode(SyncMessage.self, from: Data(payload)) else {
                    return self.close("알 수 없는 말")
                }
                self.onMessage?(m)
                self.readFrame()
            }
        }
    }
}
