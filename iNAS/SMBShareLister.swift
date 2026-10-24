import Darwin
import Foundation

/// `smbutil view`로 서버의 공유 목록을 가져온다.
/// 비밀번호는 명령줄 인자에 넣지 않는다. smbutil은 비밀번호를 터미널(/dev/tty)에서만 읽으므로
/// `/usr/bin/script`로 가상 터미널을 만들어 실행하고, "Password" 물음이 나오면 그때 입력한다.
enum SMBShareLister {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func listShares(host: String, port: Int?, username: String, password: String) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            try listSharesSync(host: host, port: port, username: username, password: password)
        }.value
    }

    private static func listSharesSync(host: String, port: Int?, username: String, password: String) throws -> [String] {
        let user = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
        let target = "//\(user)@\(host)" + (port.map { ":\($0)" } ?? "")
        let result = try run(
            ["/usr/bin/script", "-q", "/dev/null", "/usr/bin/smbutil", "view", target],
            password: password,
            timeout: 30
        )

        let shares = parse(result.output)
        // script(1)이 smbutil의 종료 코드를 그대로 돌려주지 않을 수 있으므로 출력도 함께 본다.
        guard result.status == 0, result.output.contains("shares listed") || !shares.isEmpty else {
            throw Failure(message: describeFailure(status: result.status, output: result.output, prompted: result.prompted))
        }
        return shares
    }

    /// 출력 예:
    /// ```
    /// Share                                           Type    Comments
    /// -------------------------------
    /// Media                                           Disk
    /// IPC$                                            Pipe    IPC Service
    /// ```
    static func parse(_ output: String) -> [String] {
        let pattern = /^(.+?)\s+(Disk|Pipe|Printer|Device)(\s|$)/
        var shares: [String] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard let match = line.firstMatch(of: pattern), match.output.2 == "Disk" else { continue }
            let name = String(match.output.1).trimmingCharacters(in: .whitespaces)
            if name.hasSuffix("$") { continue }   // 관리용 숨김 공유
            shares.append(name)
        }
        return shares
    }

    private static func describeFailure(status: Int32, output: String, prompted: Bool) -> String {
        let detail = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.localizedCaseInsensitiveContains("password") }
            .map { $0.replacingOccurrences(of: "smbutil: ", with: "") }
            .joined(separator: " ")
        if status == -1 { return "서버가 응답하지 않습니다." }
        if detail.localizedCaseInsensitiveContains("authentication") {
            return prompted
                ? "아이디나 비밀번호가 맞지 않습니다."
                : "인증에 실패했습니다 (비밀번호를 넘기지 못함)."
        }
        return detail.isEmpty ? "접속하지 못했습니다 (코드 \(status))." : detail
    }

    // MARK: 프로세스 실행

    private struct RunResult {
        var status: Int32
        var output: String
        var prompted: Bool
    }

    private static func run(_ arguments: [String], password: String, timeout: TimeInterval) throws -> RunResult {
        var inPipe: [Int32] = [-1, -1]
        var outPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0 else {
            throw Failure(message: "파이프를 만들지 못했습니다.")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // 위에서 지정한 것 외의 파일 디스크립터는 자식에게 넘기지 않는다.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let environment: [String] = ["LANG=C", "TERM=dumb", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        let env: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { env.forEach { free($0) } }

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, arguments[0], &actions, &attributes, argv, env)
        close(inPipe[0]); close(outPipe[1])
        guard spawnStatus == 0 else {
            close(inPipe[1]); close(outPipe[0])
            throw Failure(message: "smbutil을 실행하지 못했습니다: \(String(cString: strerror(spawnStatus)))")
        }
        let writeFD = inPipe[1]
        let readFD = outPipe[0]
        defer { close(writeFD); close(readFD) }

        let deadline = Date().addingTimeInterval(timeout)
        var output = Data()
        var prompted = false
        var timedOut = false
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                timedOut = true
                kill(pid, SIGKILL)
                break
            }
            var pfd = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining, 1) * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            let n = read(readFD, &buffer, buffer.count)
            if n <= 0 { break }   // EOF: 프로세스가 끝났다.
            output.append(buffer, count: n)

            // 비밀번호 물음이 나오면 그때 입력한다. 미리 넣으면 smbutil이 입력 버퍼를 비워 버린다.
            if !prompted, String(decoding: output, as: UTF8.self).localizedCaseInsensitiveContains("password") {
                prompted = true
                usleep(100_000)
                let line = Array((password + "\r").utf8)
                _ = line.withUnsafeBytes { write(writeFD, $0.baseAddress, $0.count) }
            }
        }

        var waitStatus: Int32 = 0
        while waitpid(pid, &waitStatus, 0) == -1 && errno == EINTR {}

        let exitCode: Int32
        if timedOut {
            exitCode = -1
        } else if waitStatus & 0x7f == 0 {
            exitCode = (waitStatus >> 8) & 0xff
        } else {
            exitCode = -1
        }
        return RunResult(status: exitCode, output: String(decoding: output, as: UTF8.self), prompted: prompted)
    }
}
