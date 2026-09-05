import XCTest
@testable import TidalDrift

final class ShellExecutorTests: XCTestCase {

    // #161: output larger than the 64 KB pipe buffer must not deadlock.
    func test_execute_drainsOutputLargerThanPipeBuffer() {
        let result = ShellExecutor.execute(
            executable: "/usr/bin/head", arguments: ["-c", "1048576", "/dev/zero"])
        XCTAssertEqual(result.exitCode, 0)
        // NUL bytes decode as UTF-8; trimming leaves them, so the count holds.
        XCTAssertEqual(result.output.utf8.count, 1_048_576)
    }

    // #165: a hung child is terminated and reported as a failure.
    func test_execute_timesOutAndTerminatesChild() {
        let start = Date()
        let result = ShellExecutor.execute(executable: "/bin/sleep", arguments: ["30"], timeout: 1)
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    // #165: PATH is pinned, so a user-writable directory cannot shadow tools.
    func test_execute_shellPathIsPinnedAndIgnoresCallerPath() throws {
        let evil = FileManager.default.temporaryDirectory
            .appendingPathComponent("evil-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: evil, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evil) }
        let fake = evil.appendingPathComponent("osascript")
        try "#!/bin/sh\necho PWNED\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        setenv("PATH", "\(evil.path):/usr/bin:/bin", 1)
        defer { setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1) }

        let path = ShellExecutor.execute("echo $PATH")
        XCTAssertEqual(path.output, "/usr/bin:/bin:/usr/sbin:/sbin")
        let which = ShellExecutor.execute("command -v osascript")
        XCTAssertEqual(which.output, "/usr/bin/osascript")
    }

    // #165: argv is passed through unchanged; no shell interprets it.
    func test_execute_executablePassesArgumentsVerbatim() {
        let result = ShellExecutor.execute(executable: "/bin/echo", arguments: ["a b", "$HOME", "; rm -rf /"])
        XCTAssertEqual(result.output, "a b $HOME ; rm -rf /")
    }
}
