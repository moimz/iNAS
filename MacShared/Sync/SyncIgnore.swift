import Foundation

/// 동기화 예외 목록 (Syncthing lib/ignore 와 같은 문법)
/// - 한 줄에 하나, 위에서부터 처음 맞는 줄이 정한다
/// - 앞에 붙는 것(순서 무관, 한 번씩): `!` 예외에서 빼기, `(?i)` 대소문자 무시, `(?d)` 폴더를 지울 때 같이 지워도 됨
/// - `/` 로 시작하면 폴더 맨 위에서만, 아니면 어느 깊이든 (`x` = `x` 와 `**/x`)
/// - `*` 는 `/` 를 넘지 않는 아무 글자, `**` 는 `/` 도 넘음, `?` 한 글자, `[...]` 글자 묶음, `\` 다음 글자 그대로
/// - `//` 로 시작하는 줄은 주석, `#include` 는 아직 안 받음(무시)
/// 경로 자신이나 위 폴더 하나라도 예외면 예외로 본다(Syncthing 은 예외 폴더를 통째로 건너뜀).
struct SyncIgnore {
    struct Result: Equatable {
        var ignored: Bool
        var deletable: Bool
    }

    private struct Pattern {
        var regex: NSRegularExpression
        var ignore: Bool
        var foldCase: Bool
        var deletable: Bool
    }

    private var patterns: [Pattern] = []
    /// 읽지 못한 줄 (화면에 알릴 것)
    private(set) var errors: [String] = []

    init(_ text: String) {
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") || line.hasPrefix("#include") { continue }
            var rest = Substring(line)
            var ignore = true, fold = false, del = false
            var seen = (neg: false, fold: false, del: false)
            while true {
                if rest.hasPrefix("!"), !seen.neg { seen.neg = true; ignore.toggle(); rest = rest.dropFirst() }
                else if rest.hasPrefix("(?i)"), !seen.fold { seen.fold = true; fold = true; rest = rest.dropFirst(4) }
                else if rest.hasPrefix("(?d)"), !seen.del { seen.del = true; del = true; rest = rest.dropFirst(4) }
                else { break }
            }
            var p = String(rest).precomposedStringWithCanonicalMapping
            if p.isEmpty { errors.append(raw); continue }
            if fold { p = p.lowercased() }
            var globs: [String]
            if p.hasPrefix("/") {
                globs = [String(p.dropFirst())]
            } else if p.hasPrefix("**/") {
                let inner = String(p.dropFirst(3))
                globs = inner.isEmpty ? [p] : [p, inner]
            } else {
                globs = [p, "**/" + p]
            }
            for g in globs {
                guard let re = Self.regex(fromGlob: g) else { errors.append(raw); continue }
                patterns.append(Pattern(regex: re, ignore: ignore, foldCase: fold, deletable: del))
            }
        }
    }

    var isEmpty: Bool { patterns.isEmpty }

    /// 이 경로 하나만 (위 폴더는 안 봄)
    func matchSelf(_ path: String) -> Result {
        let lower = path.lowercased()
        for p in patterns {
            let s = p.foldCase ? lower : path
            if p.regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
                return Result(ignored: p.ignore, deletable: p.deletable)
            }
        }
        return Result(ignored: false, deletable: false)
    }

    /// 경로나 그 위 폴더 하나라도 예외면 예외
    func match(_ path: String) -> Result {
        var r = matchSelf(path)
        if r.ignored { return r }
        var parts = path.split(separator: "/")
        while parts.count > 1 {
            parts.removeLast()
            r = matchSelf(parts.joined(separator: "/"))
            if r.ignored { return r }
        }
        return Result(ignored: false, deletable: false)
    }

    func isIgnored(_ path: String) -> Bool { match(path).ignored }

    /// 글롭 → 정규식 (구분자 /)
    private static func regex(fromGlob g: String) -> NSRegularExpression? {
        var out = "^"
        let chars = Array(g)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count, chars[i + 1] == "*" {
                    // "**/" 는 0개 이상의 폴더, 끝의 "**" 는 아무거나
                    if i + 2 < chars.count, chars[i + 2] == "/" {
                        out += "(?:.*/)?"
                        i += 3
                        continue
                    }
                    out += ".*"
                    i += 2
                    continue
                }
                out += "[^/]*"
            case "?":
                out += "[^/]"
            case "[":
                if let end = chars[(i + 1)...].firstIndex(of: "]") {
                    var cls = String(chars[(i + 1)..<end])
                    if cls.hasPrefix("!") { cls = "^" + cls.dropFirst() }
                    out += "[" + cls.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    i = end + 1
                    continue
                }
                out += "\\["
            case "\\":
                if i + 1 < chars.count {
                    out += NSRegularExpression.escapedPattern(for: String(chars[i + 1]))
                    i += 2
                    continue
                }
                out += "\\\\"
            default:
                out += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        out += "$"
        return try? NSRegularExpression(pattern: out)
    }
}
