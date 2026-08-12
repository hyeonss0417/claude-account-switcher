import Foundation

/// **진행 중인 세션을 다른 인스턴스에서 감춘다** — 같은 세션을 두 곳에서 동시에 이어가면
/// 같은 `.jsonl` 로그에 양쪽이 append 해 대화가 꼬이기 때문이다.
///
/// 판별 방식(파일만으로 안전하게):
///  - **진행 중** = 그 세션의 대화 로그(jsonl)가 최근 `busyWindow` 초 안에 쓰였다.
///    (턴이 도는 동안 로그가 계속 append 되므로 신뢰할 수 있는 신호)
///  - **소유 인스턴스** = 그 세션 인덱스 사본 중 `lastActivityAt` 이 가장 최신인 폴더.
///    (세션을 실제로 돌리는 인스턴스가 자기 인덱스를 갱신한다)
///
/// 진행 중인 동안에는 소유 인스턴스 외의 폴더에서 인덱스를 **보류(hold)** 로 빼두고,
/// 턴이 끝나 조용해지면 되돌려 놓는다. 보류본은 삭제하지 않는다.
enum SessionLock {
    /// 이 시간 안에 로그가 쓰였으면 "진행 중"으로 본다.
    static let busyWindow: TimeInterval = 90

    static var holdRoot: URL { Paths.appDir.appending(path: "held", directoryHint: .isDirectory) }

    struct Status {
        var busyHeld = 0      // 이번에 감춘 개수
        var released = 0      // 이번에 되돌린 개수
    }

    /// 폴더가 속한 **인스턴스 루트**(= <userDataDir>). 잠금은 인스턴스 간에만 적용해야 한다.
    /// 같은 인스턴스 안의 계정×조직 폴더끼리 감추면, 실제로 보고 있는 폴더에서 세션이 사라진다.
    static func instanceRoot(_ folder: URL) -> String {
        // <userDataDir>/claude-code-sessions/<acct>/<org>
        folder.deletingLastPathComponent()      // <acct>
              .deletingLastPathComponent()      // claude-code-sessions
              .deletingLastPathComponent()      // <userDataDir>
              .standardizedFileURL.path
    }

    /// 진행 중인 세션을 비소유 인스턴스에서 감추고, 끝난 세션은 되돌린다.
    @discardableResult
    static func enforce(folders: [URL]) -> Status {
        var status = Status()
        // 인스턴스가 하나뿐이면 잠글 이유가 없다(동시 사용이 아님). 보류본 회수만 수행.
        let roots = Set(folders.map(instanceRoot))
        guard roots.count > 1 else {
            status.released = releaseAll(folders: folders)
            return status
        }
        let fm = FileManager.default
        let now = Date()

        // 1) 세션(cliSessionId)별로 각 폴더의 인덱스를 모은다
        struct Entry { let folder: URL; let url: URL; let lastActivity: Double }
        var bySession: [String: [Entry]] = [:]
        var logMTime: [String: Date] = [:]

        // 인덱스 파일은 크고(평균 250KB) 수천 개다 — 전체 파싱하지 않고 헤드 스캔만 쓴다.
        for folder in folders {
            autoreleasepool {
                guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
                for item in items where item.lastPathComponent.hasPrefix("local_") && item.pathExtension == "json" {
                    autoreleasepool {
                        guard let idx = SessionIndex.load(item), let cli = idx.sessionId else { return }
                        bySession[cli, default: []].append(
                            Entry(folder: folder, url: item, lastActivity: idx.lastActivity))

                        if logMTime[cli] == nil, let log = idx.logURL,
                           let vals = try? log.resourceValues(forKeys: [.contentModificationDateKey]),
                           let m = vals.contentModificationDate {
                            logMTime[cli] = m
                        }
                    }
                }
            }
        }

        // 2) 진행 중인 세션은 소유 인스턴스만 남기고 감춘다
        for (cli, entries) in bySession {
            let busy = logMTime[cli].map { now.timeIntervalSince($0) < busyWindow } ?? false
            guard busy, entries.count > 1 else { continue }
            guard let owner = entries.max(by: { $0.lastActivity < $1.lastActivity }) else { continue }
            // 소유 **인스턴스**의 폴더들은 모두 그대로 두고, 다른 인스턴스에서만 감춘다.
            let ownerRoot = instanceRoot(owner.folder)
            var hidden = 0
            for e in entries where instanceRoot(e.folder) != ownerRoot {
                if hold(e.url, from: e.folder) { status.busyHeld += 1; hidden += 1 }
            }
            if hidden > 0 {
                Log.info("진행 중 세션 잠금: \(cli.prefix(8)) — 소유 인스턴스 유지, 다른 창 \(hidden)곳에서 감춤")
            }
        }

        // 3) 조용해진 세션은 보류본을 되돌린다
        status.released = releaseIdle(folders: folders, logMTime: logMTime, now: now)
        return status
    }

    /// 보류 중인 모든 인덱스를 조건 없이 원래 폴더로 되돌린다(잠금이 불필요해졌을 때).
    @discardableResult
    static func releaseAll(folders: [URL]) -> Int {
        let fm = FileManager.default
        var released = 0
        for folder in folders {
            let dir = holdRoot.appending(path: folderKey(folder), directoryHint: .isDirectory)
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.pathExtension == "json" {
                let back = folder.appending(path: item.lastPathComponent)
                if fm.fileExists(atPath: back.path) { try? fm.removeItem(at: item) }
                else if (try? fm.moveItem(at: item, to: back)) != nil { released += 1 }
            }
        }
        if released > 0 { Log.info("보류본 전량 회수: \(released)개") }
        return released
    }

    /// 인덱스를 보류 폴더로 옮긴다(삭제 아님).
    private static func hold(_ url: URL, from folder: URL) -> Bool {
        let fm = FileManager.default
        let key = folderKey(folder)
        let dest = holdRoot.appending(path: key, directoryHint: .isDirectory)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let target = dest.appending(path: url.lastPathComponent)
        if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
        return (try? fm.moveItem(at: url, to: target)) != nil
    }

    /// 더 이상 진행 중이 아닌 보류본을 원래 폴더로 되돌린다.
    private static func releaseIdle(folders: [URL], logMTime: [String: Date], now: Date) -> Int {
        let fm = FileManager.default
        var released = 0
        for folder in folders {
            let dir = holdRoot.appending(path: folderKey(folder), directoryHint: .isDirectory)
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.pathExtension == "json" {
                guard let data = try? Data(contentsOf: item),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let cli = obj["cliSessionId"] as? String else { continue }
                // 로그가 조용해졌으면 해제
                let stillBusy: Bool
                if let m = logMTime[cli] { stillBusy = now.timeIntervalSince(m) < busyWindow }
                else if let idx = SessionIndex.load(item), let log = idx.logURL,
                        let vals = try? log.resourceValues(forKeys: [.contentModificationDateKey]),
                        let m = vals.contentModificationDate {
                    stillBusy = now.timeIntervalSince(m) < busyWindow
                } else { stillBusy = false }
                guard !stillBusy else { continue }

                let back = folder.appending(path: item.lastPathComponent)
                if !fm.fileExists(atPath: back.path) {
                    if (try? fm.moveItem(at: item, to: back)) != nil { released += 1 }
                } else {
                    try? fm.removeItem(at: item)   // 이미 동기화로 복구됨
                }
            }
        }
        if released > 0 { Log.info("잠금 해제: \(released)개 세션을 다시 노출") }
        return released
    }

    /// 폴더를 보류 디렉터리 이름으로 인코딩.
    /// ⚠️ Swift 의 `hashValue` 는 **프로세스마다 시드가 달라** 실행할 때마다 값이 바뀐다.
    /// 그걸 쓰면 다음 실행에서 보류본을 못 찾아 영영 회수하지 못하므로, 경로를 그대로
    /// 결정적으로 인코딩한다.
    private static func folderKey(_ folder: URL) -> String {
        let path = folder.standardizedFileURL.path
        let safe = path.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "-" ? ch : "_"
        }
        // 너무 길어지지 않게 뒤쪽(고유한 부분)을 남긴다
        return String(String(safe).suffix(120))
    }

    /// 현재 진행 중(=로그가 최근에 쓰인)인 세션 수.
    static func busyCount(folders: [URL]) -> Int {
        let now = Date()
        var seen = Set<String>()
        for folder in folders {
            guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.lastPathComponent.hasPrefix("local_") && item.pathExtension == "json" {
                guard let idx = SessionIndex.load(item), let cli = idx.sessionId, !seen.contains(cli),
                      let log = idx.logURL,
                      let vals = try? log.resourceValues(forKeys: [.contentModificationDateKey]),
                      let m = vals.contentModificationDate else { continue }
                if now.timeIntervalSince(m) < busyWindow { seen.insert(cli) }
            }
        }
        return seen.count
    }
}
