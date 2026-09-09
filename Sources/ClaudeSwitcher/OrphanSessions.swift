import Foundation

/// **로그는 남아 있는데 인덱스가 사라진 세션**을 되살린다.
///
/// 세션 목록은 인덱스(local_*.json)로만 만들어지므로, 인덱스가 유실되면 대화 로그가 8MB, 100MB 씩
/// 멀쩡히 남아 있어도 목록에서 완전히 사라진다(실측: 진짜 사용자 세션 29개가 이렇게 묻혀 있었다).
///
/// 다행히 로그(jsonl) 자체가 복원에 필요한 값을 들고 있다:
///  - `{"type":"custom-title","customTitle":…}` — 제목. Claude 1.49+ 는 제목을 로그에 기록한다.
///    처음엔 worktree 이름을, 자동 제목이나 사용자의 이름 변경이 있을 때마다 새 줄을 덧붙이므로
///    **마지막 것**이 현재 제목이다(첫 것을 쓰면 `nice-gould-20ac2c` 같은 이름이 제목이 된다).
///  - `aiTitle`   — 옛 형식의 제목
///  - `cwd`       — 작업 디렉터리(로그 위치를 결정하는 값)
///  - `gitBranch` — 브랜치
/// 이 값들로 인덱스를 다시 만들면 목록에 그대로 돌아온다.
///
/// 단, **방금까지 쓰이던 로그는 건드리지 않는다.** 그 세션을 쥔 창이 곧 자기 인덱스를 쓴다 —
/// 먼저 만들면 같은 세션이 두 번 뜨고, 우리 제목이 그 창의 제목을 가린다.
enum OrphanSessions {

    struct Found {
        let sessionId: String
        let logURL: URL
        let title: String
        let cwd: String
        let branch: String
        let firstSeen: Double
        let lastSeen: Double
        let bytes: Int
    }

    /// 인덱스가 참조 중인 세션 id 전체.
    static func indexedSessionIds(folders: [URL]) -> Set<String> {
        var out = Set<String>()
        for folder in folders {
            guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.lastPathComponent.hasPrefix("local_") && item.pathExtension == "json" {
                if let idx = SessionIndex.load(item), let sid = idx.sessionId { out.insert(sid) }
            }
        }
        return out
    }

    /// 이 시간 안에 쓰인 로그는 아직 어느 창이 쥐고 있는 것으로 보고 복구하지 않는다.
    static let liveWindow: TimeInterval = 10 * 60

    /// 인덱스 없는 로그를 찾는다. `minBytes` 미만(빈 껍데기)과 서브에이전트 로그, 진행 중 로그는 제외.
    static func find(folders: [URL], minBytes: Int = 20 * 1024) -> [Found] {
        let fm = FileManager.default
        let indexed = indexedSessionIds(folders: folders)
        let now = Date()
        var out: [Found] = []
        guard let projects = try? fm.contentsOfDirectory(at: Paths.projectsDir, includingPropertiesForKeys: nil) else { return out }

        for dir in projects {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                autoreleasepool {
                    let sid = f.deletingPathExtension().lastPathComponent
                    let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    guard size >= minBytes, !indexed.contains(sid) else { return }
                    guard let info = probe(f) else { return }
                    if now.timeIntervalSince1970 * 1000 - info.last < liveWindow * 1000 { return }   // 진행 중
                    out.append(Found(sessionId: sid, logURL: f, title: info.title, cwd: info.cwd,
                                     branch: info.branch, firstSeen: info.first, lastSeen: info.last, bytes: size))
                }
            }
        }
        return out.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// 로그 앞부분에서 제목·cwd·브랜치와 시작 시각을, 파일 수정시각에서 마지막 시각을 얻는다.
    /// 100MB 짜리 로그도 있으므로 **앞부분만** 읽는다.
    private static func probe(_ url: URL) -> (title: String, cwd: String, branch: String, first: Double, last: Double)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 512 * 1024), !head.isEmpty else { return nil }
        let text = String(decoding: head, as: UTF8.self)

        var title = lastCustomTitle(in: url)
            ?? SessionIndex.scanString(text, key: "aiTitle") ?? SessionIndex.scanString(text, key: "userTitle") ?? ""
        let cwd = SessionIndex.scanString(text, key: "cwd") ?? ""
        let branch = SessionIndex.scanString(text, key: "gitBranch") ?? ""
        guard !cwd.isEmpty else { return nil }

        // 사람이 실제로 대화한 세션인지 — 서브에이전트(sidechain) 로그는 목록에 뜨는 세션이 아니므로 제외.
        guard text.contains("\"type\":\"user\"") else { return nil }
        guard !text.contains("\"isSidechain\":true") else { return nil }
        if title.isEmpty { title = URL(fileURLWithPath: cwd).lastPathComponent }

        let iso = ISO8601DateFormatter()
        var first = Date().timeIntervalSince1970 * 1000
        if let ts = SessionIndex.scanString(text, key: "timestamp"), let d = iso.date(from: ts) {
            first = d.timeIntervalSince1970 * 1000
        }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        return (title, cwd, branch, first, mtime.timeIntervalSince1970 * 1000)
    }

    /// worktree 가 이름을 바꾸면(relocated) 옛 폴더에 메타데이터만 남은 짧은 로그가, 새 폴더에 본문이 남는다.
    /// 기대 경로 하나만 보면 제목을 못 찾으므로 후보를 모두 보되 큰 파일부터 본다.
    static func lastCustomTitle(sessionId: String, expected: URL?, logIndex: [String: URL]) -> String? {
        let fm = FileManager.default
        var cands: [URL] = []
        if let e = expected, fm.fileExists(atPath: e.path) { cands.append(e) }
        if let i = logIndex[sessionId], !cands.contains(i) { cands.append(i) }
        let size: (URL) -> Int = { (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }
        for c in cands.sorted(by: { size($0) > size($1) }) {
            if let t = lastCustomTitle(in: c) { return t }
        }
        return nil
    }

    /// 로그에 기록된 **마지막** `custom-title` 값. 100MB 짜리 로그도 있으므로 메모리 맵으로 뒤에서부터 찾는다.
    static func lastCustomTitle(in log: URL) -> String? {
        guard let data = try? Data(contentsOf: log, options: .mappedIfSafe) else { return nil }
        guard let r = data.range(of: Data("\"customTitle\":\"".utf8), options: .backwards) else { return nil }
        var bytes: [UInt8] = []
        var i = r.upperBound
        while i < data.count, bytes.count < 400 {
            let b = data[i]
            if b == UInt8(ascii: "\\"), i + 1 < data.count {      // \" \\ 정도만 풀어준다
                bytes.append(data[i + 1]); i += 2; continue
            }
            if b == UInt8(ascii: "\"") { break }
            bytes.append(b); i += 1
        }
        let s = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// 우리가 복구한 인덱스의 제목을 로그의 마지막 custom-title 로 바로잡는다.
    /// (예전 복구본은 worktree 이름을 제목으로 달고 `titleSource: user` 라 Claude 도 안 고쳐 준다)
    /// - Returns: 고친 파일 수(모든 폴더의 사본 포함).
    @discardableResult
    static func retitleRecovered(folders: [URL]) -> Int {
        let fm = FileManager.default
        let logIndex = SessionIndex.buildLogIndex()
        var fixed = 0
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.lastPathComponent.hasPrefix("local_") && item.pathExtension == "json" {
                autoreleasepool {
                    guard let data = try? Data(contentsOf: item),
                          var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          obj["recoveredBy"] != nil,
                          let idx = SessionIndex.load(item) else { return }
                    guard let sid = idx.sessionId,
                          let title = lastCustomTitle(sessionId: sid, expected: idx.logURL, logIndex: logIndex),
                          title != (obj["title"] as? String) else { return }
                    obj["title"] = title
                    obj["titleSource"] = "auto"
                    guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
                          (try? out.write(to: item, options: .atomic)) != nil else { return }
                    fixed += 1
                }
            }
        }
        if fixed > 0 { Log.info("복구 인덱스 제목 정정: \(fixed)개") }
        return fixed
    }

    /// 인덱스를 다시 만들어 목록에 되돌린다. 기존 인덱스 하나를 **스키마 본**으로 삼아 형식을 맞춘다.
    @discardableResult
    static func recover(_ items: [Found], into folders: [URL]) -> Int {
        let fm = FileManager.default
        // 스키마 본 확보
        var template: [String: Any]?
        outer: for folder in folders {
            guard let list = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for f in list where f.lastPathComponent.hasPrefix("local_") && f.pathExtension == "json" {
                if let d = try? Data(contentsOf: f),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    template = o; break outer
                }
            }
        }
        guard var base = template else { Log.error("복구용 스키마 본을 찾지 못했습니다"); return 0 }
        for k in ["prNumber", "prUrl", "prRepository", "prState", "prs"] { base.removeValue(forKey: k) }

        var recovered = 0
        for item in items {
            var obj = base
            let newId = "local_\(UUID().uuidString.lowercased())"
            let origin = originRepo(of: item.cwd)
            obj["sessionId"] = newId
            obj["cliSessionId"] = item.sessionId
            obj["cwd"] = item.cwd
            obj["originCwd"] = origin
            obj["title"] = item.title
            obj["titleSource"] = "auto"      // Claude 가 나중에 더 나은 제목으로 바꿀 수 있게
            obj["recoveredBy"] = "orphan"   // 중복 정리 때 우리 사본임을 식별
            obj["branch"] = item.branch
            obj["isArchived"] = false
            obj["createdAt"] = Int(item.firstSeen)
            obj["lastActivityAt"] = Int(item.lastSeen)
            obj["lastFocusedAt"] = Int(item.lastSeen)
            // worktree 세션이면 그 정보도 채워 목록에서 같은 그룹으로 묶이게 한다
            if item.cwd.contains("/.claude/worktrees/") {
                obj["worktreePath"] = item.cwd
                obj["worktreeName"] = URL(fileURLWithPath: item.cwd).lastPathComponent
            } else {
                obj.removeValue(forKey: "worktreePath")
                obj.removeValue(forKey: "worktreeName")
            }
            // 키 정렬: cliSessionId·cwd 가 앞쪽에 와야 헤드 스캔(앞 16KB)이 인식한다.
            // 정렬 없이 쓰면 큰 필드 뒤로 밀려 '인덱스 없음'으로 오판 → 재시작마다 사본이 하나씩 늘었다.
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { continue }
            for folder in folders {
                try? data.write(to: folder.appending(path: "\(newId).json"), options: .atomic)
            }
            recovered += 1
            Log.info("고아 세션 복구: \(item.title) (\(item.bytes / 1024)KB)")
        }
        return recovered
    }

    /// `/repo/.claude/worktrees/xxx` → `/repo`
    private static func originRepo(of cwd: String) -> String {
        guard let r = cwd.range(of: "/.claude/worktrees/") else { return cwd }
        return String(cwd[..<r.lowerBound])
    }
}
