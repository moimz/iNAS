import CryptoKit
import Foundation

// 동기화 엔진의 자료 (Syncthing BEP 를 본뜸, Ai/iNAS/동기화-설계.md).
// 앱(AppKit · CloudKit)에 기대지 않는다: 시험 장치(Ai/iNAS/sync-harness)에서도 그대로 컴파일한다.

/// 기기 짧은 아이디 = 공개 키 SHA-256 앞 8바이트 (버전 벡터 칸)
typealias ShortID = UInt64

/// 버전 벡터: 기기마다 카운터. 아이디 순으로 정렬해 둔다 (Syncthing lib/protocol/vector.go)
struct SyncVector: Codable, Equatable, Hashable {
    struct Counter: Codable, Equatable, Hashable {
        var id: ShortID
        var value: UInt64
    }

    var counters: [Counter] = []

    enum Ordering { case equal, greater, lesser, concurrentGreater, concurrentLesser }

    /// 내 카운터를 올린다: max(이전 + 1, 지금 초) (Syncthing updateWithNow)
    func updated(_ id: ShortID, now: UInt64 = UInt64(Date().timeIntervalSince1970)) -> SyncVector {
        var v = self
        for i in v.counters.indices {
            if v.counters[i].id == id {
                v.counters[i].value = max(v.counters[i].value + 1, now)
                return v
            } else if v.counters[i].id > id {
                v.counters.insert(Counter(id: id, value: max(1, now)), at: i)
                return v
            }
        }
        v.counters.append(Counter(id: id, value: max(1, now)))
        return v
    }

    func counter(_ id: ShortID) -> UInt64 { counters.first { $0.id == id }?.value ?? 0 }

    /// Syncthing Vector.Compare 그대로
    func compare(_ b: SyncVector) -> Ordering {
        var ai = 0, bi = 0
        var result = Ordering.equal
        let a = counters, bc = b.counters
        while ai < a.count || bi < bc.count {
            var aMissing = false, bMissing = false
            var av = Counter(id: 0, value: 0), bv = Counter(id: 0, value: 0)
            if ai < a.count { av = a[ai] } else { aMissing = true }
            if bi < bc.count { bv = bc[bi] } else { bMissing = true }
            if !aMissing && !bMissing && av.id == bv.id {
                if av.value > bv.value {
                    if result == .lesser { return .concurrentLesser }
                    result = .greater
                } else if av.value < bv.value {
                    if result == .greater { return .concurrentGreater }
                    result = .lesser
                }
            } else if (!aMissing && av.id < bv.id) || bMissing {
                if av.value > 0 {
                    if result == .lesser { return .concurrentLesser }
                    result = .greater
                }
            } else if (!bMissing && bv.id < av.id) || aMissing {
                if bv.value > 0 {
                    if result == .greater { return .concurrentGreater }
                    result = .lesser
                }
            }
            if ai < a.count && (av.id <= bv.id || bMissing) { ai += 1 }
            if bi < bc.count && (bv.id <= av.id || aMissing) { bi += 1 }
        }
        return result
    }

    func greaterEqual(_ b: SyncVector) -> Bool {
        let c = compare(b)
        return c == .greater || c == .equal
    }
}

/// 파일 안 블록 하나
struct SyncBlock: Codable, Equatable, Hashable {
    var offset: Int64
    var size: Int32
    var hash: Data
}

/// 파일 목록 한 항목 (Syncthing FileInfo)
struct SyncFile: Codable, Equatable {
    enum Kind: Int, Codable { case file = 0, directory = 1, symlink = 2 }

    /// NFC, "/" 로 나눈 폴더 기준 경로
    var name: String
    var kind: Kind
    var size: Int64
    /// 수정 시각 (1970 부터 나노초)
    var modified: Int64
    var permissions: UInt32
    var deleted: Bool
    var version: SyncVector
    /// 이 항목을 알린 기기의 순번 (그 기기 안에서 커짐)
    var sequence: Int64
    var blocks: [SyncBlock]
    /// 블록 해시를 이어 붙인 것의 SHA-256 (내용 전체를 대표)
    var blocksHash: Data?
    /// 바뀌기 전 내용의 blocksHash (충돌 판단에 씀)
    var previousBlocksHash: Data?
    var modifiedBy: ShortID
    var symlinkTarget: String?

    var modifiedDate: Date { Date(timeIntervalSince1970: TimeInterval(modified) / 1e9) }

    /// 내용이 같은지 (Syncthing BlocksEqual)
    func blocksEqual(_ o: SyncFile) -> Bool {
        if let a = blocksHash, let b = o.blocksHash { return a == b }
        return blocks == o.blocks
    }

    /// 이 새 파일이 지금 내 파일(previous)과 충돌인지 (Syncthing InConflictWith)
    func inConflict(with previous: SyncFile) -> Bool {
        if version.greaterEqual(previous.version) { return false }
        guard let prev = previousBlocksHash, let cur = previous.blocksHash, kind == previous.kind else { return true }
        return prev != cur
    }

    /// 동시 버전일 때 이 쪽을 고를지 (Syncthing WinsConflict): 수정 시각 늦은 쪽, 같으면 벡터 순서
    func winsConflict(_ other: SyncFile) -> Bool {
        if modified != other.modified { return modified > other.modified }
        return version.compare(other.version) == .concurrentGreater
    }

    /// 전역 버전을 고를 때 이 쪽이 나은지 (Syncthing fileRow.Compare)
    func isBetter(than other: SyncFile) -> Bool {
        switch version.compare(other.version) {
        case .greater: return true
        case .lesser, .equal: return false
        case .concurrentGreater, .concurrentLesser: return winsConflict(other)
        }
    }

    /// 블록 크기: 128KiB 부터 두 배씩, 블록이 2000개를 넘지 않게, 최대 16MiB (Syncthing BlockSize)
    static func blockSize(for size: Int64) -> Int {
        var bs = 128 << 10
        while bs < (16 << 20) && size / Int64(bs) > 2000 { bs <<= 1 }
        return bs
    }

    static func hashOfBlocks(_ blocks: [SyncBlock]) -> Data {
        var h = SHA256()
        for b in blocks { h.update(data: b.hash) }
        return Data(h.finalize())
    }
}

/// 기기 신원: Curve25519 키 한 쌍. 기기 아이디 = 공개 키 SHA-256 (hex)
struct SyncIdentity {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }
    var keyID: String { Self.keyID(of: publicKey.rawRepresentation) }
    var shortID: ShortID { Self.shortID(of: publicKey.rawRepresentation) }

    static func keyID(of publicKey: Data) -> String {
        SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    }

    static func shortID(of publicKey: Data) -> ShortID {
        SHA256.hash(data: publicKey).prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// 두 기기만 아는 키 (ECDH → HKDF). 기기 아이디 둘을 정렬해 섞어 두 쪽이 같은 값을 얻는다
    func pairKey(with peer: Curve25519.KeyAgreement.PublicKey) throws -> SymmetricKey {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let ids = [keyID, Self.keyID(of: peer.rawRepresentation)].sorted().joined(separator: ":")
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("iNAS-sync-v1".utf8), sharedInfo: Data(ids.utf8), outputByteCount: 32)
    }
}

/// 다른 기기 (공개 키는 iCloud 기기 기록에서 옴)
struct SyncPeer: Equatable {
    var publicKey: Data
    var name: String
    var keyID: String { SyncIdentity.keyID(of: publicKey) }
    var shortID: ShortID { SyncIdentity.shortID(of: publicKey) }
}

/// 동기화할 폴더 하나의 이 기기 설정
struct SyncFolderConfig: Equatable {
    var id: String
    var name: String
    var path: String
    var ignores: String
    /// 전체 재탐색 간격(초), 0 = 끔 (Syncthing 기본 1시간, 이 Mac 설정)
    var rescanInterval: TimeInterval = 3600
}
