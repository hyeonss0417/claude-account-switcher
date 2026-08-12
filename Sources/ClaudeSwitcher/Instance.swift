import Foundation
import AppKit

/// 계정 하나에 대응하는 **독립 Claude 데스크탑 인스턴스**.
///
/// Electron 의 `--user-data-dir` 로 데이터 디렉터리를 계정마다 분리하면
/// 쿠키(=로그인)도 분리되어 **여러 계정을 동시에 띄울 수 있다**(실측 확인).
/// 세션 인덱스도 각 인스턴스의 `<userDataDir>/claude-code-sessions/` 아래에 따로 생기므로,
/// 인스턴스 간 합집합 동기화로 "A 에서 하던 작업을 B 에서 이어가기"가 가능해진다.
struct Instance {
    let accountUuid: String
    let dataDir: URL
    var pid: pid_t?

    var isRunning: Bool { pid != nil }
    var sessionsBase: URL { dataDir.appending(path: "claude-code-sessions", directoryHint: .isDirectory) }
}

enum InstanceManager {
    /// 기본(원래) 인스턴스는 accountUuid 대신 이 키를 쓴다.
    static let defaultKey = "default"

    static var instancesRoot: URL {
        Paths.appDir.appending(path: "instances", directoryHint: .isDirectory)
    }

    static func dataDir(for accountUuid: String) -> URL {
        accountUuid == defaultKey ? Paths.appSupportClaude
                                  : instancesRoot.appending(path: accountUuid, directoryHint: .isDirectory)
    }

    // MARK: - 실행 중인 인스턴스 파악
    /// `ps` 로 Claude 프로세스들의 `--user-data-dir` 을 읽어 어떤 인스턴스가 떠 있는지 판별.
    static func runningDataDirs() -> [String: pid_t] {
        var out: [String: pid_t] = [:]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return out }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return out }

        for line in text.split(separator: "\n") {
            guard line.contains("Claude.app/Contents/MacOS/Claude") else { continue }
            // 헬퍼 프로세스 제외 (Helper 는 별도 실행파일명을 가진다)
            if line.contains("Helper") { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let pidStr = trimmed.split(separator: " ").first, let pid = pid_t(pidStr) else { continue }
            if let r = trimmed.range(of: "--user-data-dir=") {
                let rest = trimmed[r.upperBound...]
                let path = String(rest.prefix(while: { $0 != " " }))
                out[URL(fileURLWithPath: path).standardizedFileURL.path] = pid
            } else {
                out[Paths.appSupportClaude.standardizedFileURL.path] = pid
            }
        }
        return out
    }

    /// 등록된(=디렉터리가 있는) 인스턴스 + 기본 인스턴스 목록.
    static func list(knownAccounts: [String]) -> [Instance] {
        let running = runningDataDirs()
        var result: [Instance] = []
        // 기본 인스턴스
        let defDir = Paths.appSupportClaude
        result.append(Instance(accountUuid: defaultKey, dataDir: defDir,
                               pid: running[defDir.standardizedFileURL.path]))
        for acct in knownAccounts {
            let dir = dataDir(for: acct)
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            result.append(Instance(accountUuid: acct, dataDir: dir,
                                   pid: running[dir.standardizedFileURL.path]))
        }
        return result
    }

    static func exists(accountUuid: String) -> Bool {
        FileManager.default.fileExists(atPath: dataDir(for: accountUuid).path)
    }

    // MARK: - 생성 / 실행
    /// 인스턴스 데이터 디렉터리를 만들고, 저장된 웹세션으로 시드해 **로그인된 상태로** 시작하게 한다.
    @discardableResult
    static func createIfNeeded(accountUuid: String) -> Bool {
        let dir = dataDir(for: accountUuid)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // 저장된 웹세션(쿠키/스토리지)을 넣어주면 로그인 화면을 건너뛴다.
        let snap = WebSession.snapshotDir(accountUuid: accountUuid)
        guard fm.fileExists(atPath: snap.path) else {
            Log.info("인스턴스 \(accountUuid.prefix(8)): 저장된 로그인 없음 → 최초 1회 수동 로그인 필요")
            return false
        }
        for name in ["Cookies", "Cookies-journal", "Local Storage", "Session Storage"] {
            let src = snap.appending(path: name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = dir.appending(path: name)
            if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
            try? fm.copyItem(at: src, to: dst)
        }
        Log.info("인스턴스 \(accountUuid.prefix(8)) 준비 완료(로그인 시드됨)")
        return true
    }

    /// 인스턴스를 새 프로세스로 띄운다. 이미 떠 있으면 앞으로 가져온다.
    @discardableResult
    static func launch(accountUuid: String) -> Bool {
        let dir = dataDir(for: accountUuid)
        if let pid = runningDataDirs()[dir.standardizedFileURL.path] {
            NSRunningApplication(processIdentifier: pid)?.activate()
            return true
        }
        createIfNeeded(accountUuid: accountUuid)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -n: 새 인스턴스 강제. --args 뒤는 앱에 전달되는 스위치.
        task.arguments = ["-n", "-a", "/Applications/Claude.app", "--args", "--user-data-dir=\(dir.path)"]
        do { try task.run() } catch {
            Log.error("인스턴스 실행 실패 \(accountUuid.prefix(8)): \(error.localizedDescription)")
            return false
        }
        Log.info("인스턴스 실행: \(accountUuid.prefix(8))")
        return true
    }

    /// 모든 인스턴스(기본 포함)의 세션 폴더(<acct>/<org>)를 모아준다 — 동기화 대상.
    ///
    /// `profiles` 를 주면 **아직 없는 인스턴스 세션 폴더를 미리 만들어** 동기화 대상에 포함시킨다.
    /// (새 인스턴스는 로그인 후에야 폴더가 생겨서, 그 전 동기화에서 누락돼 목록이 빈 채로 시작한다)
    static func allSessionFolders(knownAccounts: [String], profiles: [Profile] = []) -> [URL] {
        let fm = FileManager.default
        var roots: [URL] = [Paths.sessionsBase]
        for acct in knownAccounts {
            let base = dataDir(for: acct).appending(path: "claude-code-sessions", directoryHint: .isDirectory)
            // 인스턴스 디렉터리가 있으면, 그 계정의 <acct>/<org> 경로를 미리 만들어 둔다.
            if fm.fileExists(atPath: dataDir(for: acct).path),
               let p = profiles.first(where: { $0.accountUuid == acct }) {
                let target = base.appending(path: p.accountUuid).appending(path: p.organizationUuid)
                if !fm.fileExists(atPath: target.path) {
                    try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                    Log.info("인스턴스 세션 폴더 생성: \(acct.prefix(8))")
                }
            }
            if fm.fileExists(atPath: base.path) { roots.append(base) }
        }
        var folders: [URL] = []
        for root in roots {
            guard let accts = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for a in accts {
                guard UUID(uuidString: a.lastPathComponent) != nil else { continue }
                guard let orgs = try? fm.contentsOfDirectory(at: a, includingPropertiesForKeys: nil) else { continue }
                for o in orgs where UUID(uuidString: o.lastPathComponent) != nil { folders.append(o) }
            }
        }
        return folders
    }
}
