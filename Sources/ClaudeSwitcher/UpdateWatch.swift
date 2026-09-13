import AppKit

/// Claude 데스크탑 **자동 업데이트의 진행 단계**와, 창마다 **지금 돌고 있는 세션**을 알아낸다.
///
/// 배경(실측, 2026-09-12~14): 업데이트가 내려받아지면 Claude 는 창이 10분간 쓰이지 않을 때
/// `stealth-update` 로 **스스로 종료**한다. 이때 켜둔 세션과 백그라운드 작업이 함께 끊긴다
/// ("Stopping 6 active session(s) on quit"). 그런데 다른 계정 창이 같은 앱 번들을 붙잡고 있으면
/// 설치기(ShipIt)가 "App Still Running Error" 로 포기하고, 업데이트는 계속 대기 상태로 남는다 —
/// 그래서 **같은 종료가 한 시간 간격으로 반복**됐다(05:54, 06:54, 11:46, 다음날 02:47 …).
///
/// ShipIt 은 내려받은 앱이 종료되기를 기다리다가(`Detected this as an install request`),
/// 그 창이 꺼지면 `Beginning installation` 을 찍고 나머지 창이 닫히기를 약 10초 기다린다.
/// 그 사이 창이 하나라도 남아 있거나 새로 뜨면 설치를 취소한다.
enum UpdateWatch {

    enum Phase: Equatable {
        case none                  // 대기 중인 업데이트 없음
        case staged(pid: Int32)    // 설치기가 창 종료를 기다리는 중
        case installing(pid: Int32) // 설치 시작됨 — 지금 창을 띄우면 설치가 실패한다
    }

    private static let shipItLog = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Caches/com.anthropic.claudefordesktop.ShipIt/ShipIt_stderr.log")

    /// 지금의 업데이트 단계. ShipIt 프로세스와 그 로그로 판별한다.
    static func phase() -> Phase {
        guard let pid = runningShipItPids().max() else { return .none }
        // 로그 끝부분에서 이 pid 의 줄만 본다(ShipIt[<pid>:<thread>] 형식).
        let tail = readTail(shipItLog, bytes: 64 * 1024)
        let mine = tail.split(separator: "\n").filter { $0.contains("ShipIt[\(pid):") }
        if mine.contains(where: { $0.contains("Beginning installation") }) { return .installing(pid: pid) }
        return .staged(pid: pid)
    }

    static var isInstalling: Bool {
        if case .installing = phase() { return true }
        return false
    }

    /// 설치된 버전.
    static func installedVersion() -> String {
        let plist = URL(fileURLWithPath: "/Applications/Claude.app/Contents/Info.plist")
        let dict = NSDictionary(contentsOf: plist)
        return dict?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// 내려받아 설치를 기다리는 버전(없으면 nil). Claude 로그의 마지막 "ready to install" 줄.
    static func stagedVersion() -> String? {
        guard case .staged = phase() else { return nil }
        for name in ["main.log", "main1.log"] {           // 로그가 막 교체됐을 수 있어 직전 파일도 본다
            let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Claude/\(name)")
            let text = readTail(url, bytes: 512 * 1024)
            if let r = text.range(of: "ready to install { releaseName: 'Claude ", options: .backwards) {
                let v = text[r.upperBound...].prefix { $0 != "'" }
                if !v.isEmpty { return String(v) }
            }
        }
        return "새 버전"
    }

    /// 설치가 시작되기를 `startWithin` 초까지 기다린 뒤, 설치가 끝날 때까지(최대 `timeout`) 기다린다.
    /// 메인 스레드에서 부르지 말 것.
    /// - Returns: 설치가 시작된 적이 있는가.
    @discardableResult
    static func waitForInstall(startWithin: TimeInterval, timeout: TimeInterval) -> Bool {
        var started = false
        let startDeadline = Date().addingTimeInterval(startWithin)
        while Date() < startDeadline {
            if isInstalling { started = true; break }
            if case .none = phase() { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard started else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, isInstalling { Thread.sleep(forTimeInterval: 1) }
        Thread.sleep(forTimeInterval: 2)                      // 번들 교체 직후 여유
        return true
    }

    /// 설치가 진행 중이면 끝날 때까지 기다린다(최대 `timeout`). 메인 스레드에서 부르지 말 것.
    static func waitWhileInstalling(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        var waited = false
        while Date() < deadline, isInstalling { waited = true; Thread.sleep(forTimeInterval: 1) }
        if waited { Thread.sleep(forTimeInterval: 2) }
    }

    // MARK: - 창별 진행 중 세션

    /// 이 창(Claude 메인 프로세스)에서 **최근 `recent` 초 안에 대화 로그를 쓴** 세션 수.
    ///
    /// Claude Code 세션 프로세스는 `~/.claude/sessions/<pid>.json` 에 자기 세션 id·cwd 를 남기고,
    /// 창 프로세스의 손자로 뜬다(창 → disclaimer → claude). 그 로그가 방금 쓰였으면 턴이 돌거나
    /// 백그라운드 작업이 살아 있는 것이다 — 이 창을 닫으면 끊긴다.
    static func busySessions(windowPid: pid_t, recent: TimeInterval = 120) -> Int {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appending(path: ".claude/sessions")
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return 0 }
        let parents = parentMap()
        let now = Date()
        var busy = 0
        for item in items where item.pathExtension == "json" {
            guard let pid = pid_t(item.deletingPathExtension().lastPathComponent),
                  isDescendant(pid, of: windowPid, parents: parents),
                  let data = try? Data(contentsOf: item),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["sessionId"] as? String, let cwd = obj["cwd"] as? String else { continue }
            let log = Paths.projectsDir.appending(path: SessionIndex.encodeProjectDir(cwd)).appending(path: "\(sid).jsonl")
            guard let m = (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            if now.timeIntervalSince(m) < recent { busy += 1 }
        }
        return busy
    }

    // MARK: - 내부

    private static func runningShipItPids() -> [Int32] {
        let out = run("/usr/bin/pgrep", ["-f", "claudefordesktop.ShipIt"])
        return out.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func parentMap() -> [pid_t: pid_t] {
        var map: [pid_t: pid_t] = [:]
        for line in run("/bin/ps", ["-axo", "pid=,ppid="]).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, let p = pid_t(parts[0]), let pp = pid_t(parts[1]) { map[p] = pp }
        }
        return map
    }

    private static func isDescendant(_ pid: pid_t, of ancestor: pid_t, parents: [pid_t: pid_t]) -> Bool {
        var cur = pid
        for _ in 0..<8 {
            guard let p = parents[cur], p > 1 else { return false }
            if p == ancestor { return true }
            cur = p
        }
        return false
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// 파일 끝 `bytes` 만큼을 문자열로. 멀티바이트 문자 중간에서 잘려도 실패하지 않게 관대하게 디코딩한다.
    private static func readTail(_ url: URL, bytes: UInt64) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > bytes ? size - bytes : 0)
        return String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
    }
}
