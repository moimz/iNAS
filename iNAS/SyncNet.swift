import Foundation
import IOKit
import Network
import SystemConfiguration

// 동기화 시험(sync-discovery-test 브랜치): 기기 정보 · 공인 IP(STUN) · 공유기 포트 열기(UPnP) · 대기와 연결 확인.
// 나중에 상주 에이전트로 옮기기 쉽게 화면과 떨어뜨려 둔다.

/// 이 맥의 이름 · 종류 · IP
enum DeviceInfo {
    /// 시스템 설정 > 일반 > 정보 의 이름 ("Mac", "MacBook")
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    /// "Mac16,11"
    static var modelIdentifier: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// "Mac mini (2024)", "MacBook Pro (14-inch, M3, Nov 2023)" — Apple 실리콘의 IODeviceTree:/product
    static var productName: String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let s = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }

    /// 기본 경로로 나가는 내부 IPv4. UDP 소켓을 connect 만 하고(패킷은 안 보냄) 고른 주소를 읽는다.
    static func primaryIPv4() -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = in_port_t(53).bigEndian
        inet_pton(AF_INET, "1.1.1.1", &dst.sin_addr)
        let ok = withUnsafePointer(to: &dst) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { return nil }
        var me = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &me) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { return nil }
        return ipString(me.sin_addr)
    }

    static func ipString(_ addr: in_addr) -> String {
        var a = addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    /// 10/8 · 172.16/12 · 192.168/16 · 100.64/10(통신사 NAT) · 169.254/16
    static func isPrivate(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
            || (p[0] == 100 && (64...127).contains(p[1])) || (p[0] == 169 && p[1] == 254)
    }
}

struct NetError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// 막히는 소켓 작업을 메인 밖에서
func offMain<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await Task.detached(priority: .utility) { try work() }.value
}

// MARK: - STUN (공인 IP)

enum STUN {
    static let servers: [(String, UInt16)] = [("stun.l.google.com", 19302), ("stun.cloudflare.com", 3478)]

    /// 차례로 물어 처음 답한 곳의 (공인 IP, 바깥에서 본 UDP 포트)
    static func publicAddress() async throws -> (ip: String, port: UInt16, server: String) {
        var last: Error = NetError("STUN 서버 없음")
        for (host, port) in servers {
            do {
                let r = try await offMain { try query(host: host, port: port) }
                return (r.0, r.1, host)
            } catch { last = error }
        }
        throw last
    }

    /// RFC 5389 Binding 요청 하나 보내고 XOR-MAPPED-ADDRESS 를 읽는다
    static func query(host: String, port: UInt16) throws -> (String, UInt16) {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { throw NetError("\(host) 주소를 못 찾음") }
        defer { freeaddrinfo(res) }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw NetError("소켓 실패") }
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var req = [UInt8](repeating: 0, count: 20)
        req[1] = 0x01
        req[4] = 0x21; req[5] = 0x12; req[6] = 0xA4; req[7] = 0x42
        for i in 8..<20 { req[i] = UInt8.random(in: 0...255) }
        guard sendto(fd, req, req.count, 0, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == req.count else {
            throw NetError("\(host) 에 못 보냄")
        }
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = recv(fd, &buf, buf.count, 0)
        guard n >= 20 else { throw NetError("\(host) 답 없음") }
        guard buf[0] == 0x01, buf[1] == 0x01, Array(buf[8..<20]) == Array(req[8..<20]) else { throw NetError("\(host) 답이 이상함") }
        var i = 20
        var mapped: (String, UInt16)?
        while i + 4 <= n {
            let type = Int(buf[i]) << 8 | Int(buf[i + 1])
            let len = Int(buf[i + 2]) << 8 | Int(buf[i + 3])
            let v = i + 4
            guard v + len <= n else { break }
            if (type == 0x0020 || type == 0x0001), len >= 8, buf[v + 1] == 0x01 {
                let xor = type == 0x0020
                var p = UInt16(buf[v + 2]) << 8 | UInt16(buf[v + 3])
                var b = Array(buf[(v + 4)..<(v + 8)])
                if xor {
                    p ^= 0x2112
                    b[0] ^= 0x21; b[1] ^= 0x12; b[2] ^= 0xA4; b[3] ^= 0x42
                }
                let r = ("\(b[0]).\(b[1]).\(b[2]).\(b[3])", p)
                if xor { return r }
                mapped = r
            }
            i = v + ((len + 3) & ~3)
        }
        if let mapped { return mapped }
        throw NetError("\(host) 답에 주소 없음")
    }
}

// MARK: - UPnP (공유기 포트 열기)

struct UPnPGateway {
    let controlURL: URL
    let serviceType: String
    let name: String
}

struct UPnPFault: LocalizedError {
    let code: Int
    let text: String
    var errorDescription: String? { "UPnP 오류 \(code) \(text)" }
}

enum UPnP {
    /// SSDP 로 공유기(IGD)를 찾고 설명 XML 에서 WANIPConnection(또는 WANPPPConnection) 제어 주소를 읽는다
    static func findGateway() async throws -> UPnPGateway {
        let location = try await offMain { try discover() }
        let (data, _) = try await URLSession.shared.data(from: location)
        let d = DescriptionParser(data: data)
        guard let control = d.controlURL, let url = URL(string: control, relativeTo: location)?.absoluteURL else {
            throw NetError("공유기 설명에 WANIPConnection 없음")
        }
        return UPnPGateway(controlURL: url, serviceType: d.serviceType ?? "", name: d.modelName ?? d.friendlyName ?? location.host ?? "공유기")
    }

    static func discover() throws -> URL {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw NetError("소켓 실패") }
        defer { close(fd) }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(1))
        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &dst.sin_addr)
        for st in ["urn:schemas-upnp-org:device:InternetGatewayDevice:1", "urn:schemas-upnp-org:device:InternetGatewayDevice:2"] {
            let msg = Array("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(st)\r\n\r\n".utf8)
            _ = withUnsafePointer(to: &dst) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { throw NetError("공유기가 UPnP 에 답하지 않음") }
            let text = String(decoding: buf[0..<n], as: UTF8.self)
            for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
                let v = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
                if let url = URL(string: v) { return url }
            }
        }
    }

    static func soap(_ gw: UPnPGateway, _ action: String, _ args: [(String, String)] = []) async throws -> [String: String] {
        let body = args.map { "<\($0.0)>\($0.1)</\($0.0)>" }.joined()
        let xml = """
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(gw.serviceType)">\(body)</u:\(action)></s:Body></s:Envelope>
        """
        var req = URLRequest(url: gw.controlURL, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(gw.serviceType)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = Data(xml.utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let fields = LeafParser(data: data).fields
        if (response as? HTTPURLResponse)?.statusCode != 200 {
            throw UPnPFault(code: Int(fields["errorCode"] ?? "") ?? -1, text: fields["errorDescription"] ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return fields
    }

    static func externalIP(_ gw: UPnPGateway) async throws -> String {
        guard let ip = try await soap(gw, "GetExternalIPAddress")["NewExternalIPAddress"], !ip.isEmpty else {
            throw NetError("공유기가 바깥 IP 를 안 알려 줌")
        }
        return ip
    }

    static func addMapping(_ gw: UPnPGateway, external: UInt16, internal internalPort: UInt16, client: String, lease: Int) async throws {
        _ = try await soap(gw, "AddPortMapping", [
            ("NewRemoteHost", ""), ("NewExternalPort", "\(external)"), ("NewProtocol", "TCP"),
            ("NewInternalPort", "\(internalPort)"), ("NewInternalClient", client), ("NewEnabled", "1"),
            ("NewPortMappingDescription", "iNAS sync"), ("NewLeaseDuration", "\(lease)"),
        ])
    }

    /// 그 바깥 포트가 이미 누구에게 열려 있는지 (없으면 nil)
    static func mappingClient(_ gw: UPnPGateway, external: UInt16) async -> (client: String, port: String)? {
        guard let f = try? await soap(gw, "GetSpecificPortMappingEntry", [
            ("NewRemoteHost", ""), ("NewExternalPort", "\(external)"), ("NewProtocol", "TCP"),
        ]) else { return nil }
        return (f["NewInternalClient"] ?? "", f["NewInternalPort"] ?? "")
    }

    static func deleteMapping(_ gw: UPnPGateway, external: UInt16) async {
        _ = try? await soap(gw, "DeletePortMapping", [("NewRemoteHost", ""), ("NewExternalPort", "\(external)"), ("NewProtocol", "TCP")])
    }

    /// 설명 XML: service 묶음 가운데 WANIPConnection / WANPPPConnection 의 serviceType · controlURL
    private final class DescriptionParser: NSObject, XMLParserDelegate {
        var controlURL: String?
        var serviceType: String?
        var friendlyName: String?
        var modelName: String?
        private var text = ""
        private var curType: String?
        private var curControl: String?

        init(data: Data) {
            super.init()
            let p = XMLParser(data: data)
            p.delegate = self
            p.parse()
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "service" { curType = nil; curControl = nil }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "serviceType": curType = t
            case "controlURL": curControl = t
            case "friendlyName": if friendlyName == nil { friendlyName = t }
            case "modelName": if modelName == nil { modelName = t }
            case "service":
                if controlURL == nil, let type = curType,
                   type.contains("WANIPConnection") || type.contains("WANPPPConnection") {
                    serviceType = type
                    controlURL = curControl
                }
            default: break
            }
            text = ""
        }
    }

    /// SOAP 답: 맨 끝 요소들의 이름(접두어 뺀) → 글
    private final class LeafParser: NSObject, XMLParserDelegate {
        var fields: [String: String] = [:]
        private var text = ""

        init(data: Data) {
            super.init()
            let p = XMLParser(data: data)
            p.delegate = self
            p.parse()
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) { text = "" }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let key = name.split(separator: ":").last.map(String.init) ?? name
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if fields[key] == nil, !t.isEmpty { fields[key] = t }
            text = ""
        }
    }
}

// MARK: - 대기 · 연결 (줄 단위 JSON. 아직 인사 · 신호만, 실제 동기화와 암호화는 다음 단계)

/// 주고받는 한 줄: hello(누구), ping/pong(살아 있음, n 으로 짝)
struct SyncMsg: Codable {
    var app = "iNAS-sync"
    var v = 2
    var t: String
    var id: String?
    var name: String?
    var n: Int?
}

/// NWConnection 위에 줄 단위 JSON 주고받기. 콜백은 큐에서 불린다.
final class LineConnection {
    let conn: NWConnection
    let queue: DispatchQueue
    let remote: String
    var onReady: (() -> Void)?
    var onMessage: ((SyncMsg) -> Void)?
    var onClose: ((String?) -> Void)?
    private var buffer = Data()
    private var closed = false

    init(_ conn: NWConnection, queue: DispatchQueue) {
        self.conn = conn
        self.queue = queue
        if case .hostPort(let host, let port) = conn.endpoint { remote = "\(host):\(port)" } else { remote = "\(conn.endpoint)" }
    }

    convenience init(host: String, port: UInt16, queue: DispatchQueue) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 8
        tcp.enableKeepalive = true
        self.init(NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: nil, tcp: tcp)), queue: queue)
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receive()
            case .failed(let e): self.close(e.localizedDescription)
            case .waiting(let e): self.close(e.localizedDescription)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    func send(_ m: SyncMsg) {
        guard !closed, var data = try? JSONEncoder().encode(m) else { return }
        data.append(0x0A)
        conn.send(content: data, completion: .contentProcessed { [weak self] e in
            if let e { self?.queue.async { self?.close(e.localizedDescription) } }
        })
    }

    /// 큐에서 부른다
    func close(_ reason: String?) {
        guard !closed else { return }
        closed = true
        conn.cancel()
        onClose?(reason)
        onReady = nil; onMessage = nil; onClose = nil
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer[self.buffer.startIndex..<nl]
                self.buffer = Data(self.buffer[(nl + 1)...])
                guard let m = try? JSONDecoder().decode(SyncMsg.self, from: line), m.app == "iNAS-sync" else {
                    return self.close("알 수 없는 말")
                }
                self.onMessage?(m)
                if self.closed { return }
            }
            if self.buffer.count > 65536 { return self.close("줄이 너무 김") }
            if let error { return self.close(error.localizedDescription) }
            if complete { return self.close("저쪽이 끊음") }
            self.receive()
        }
    }
}

final class SyncListener {
    private var listener: NWListener?
    let queue = DispatchQueue(label: "iNAS.sync.net")
    private(set) var port: UInt16 = 0
    /// 새로 들어온 연결 (큐에서 불린다)
    var onConnection: ((LineConnection) -> Void)?

    /// 이 포트에서 대기 (이미 쓰이면 실패)
    func start(port: UInt16) async throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return c.cancel() }
            self.onConnection?(LineConnection(c, queue: self.queue))
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { cont.resume() }
                case .failed(let e): once.run { cont.resume(throwing: e) }
                case .waiting(let e): once.run { cont.resume(throwing: e) }
                default: break
                }
            }
            l.start(queue: queue)
        }
        listener = l
        self.port = port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }
}

/// 한 번만 실행
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ f: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { f() }
    }
}
