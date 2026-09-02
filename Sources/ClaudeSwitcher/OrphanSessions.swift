import Foundation

/// **로그는 남아 있는데 인덱스가 사라진 세션**을 되살린다.
///
/// 세션 목록은 인덱스(local_*.json)로만 만들어지므로, 인덱스가 유실되면 대화 로그가 8MB, 100MB 씩
/// 멀쩡히 남아 있어도 목록에서 완전히 사라진다(실측: 진짜 사용자 세션 29개가 이렇게 묻혀 있었다).
///
/// 다행히 로그(jsonl) 자체가 복원에 필요한 값을 들고 있다:
///  - `aiTitle`   — 세션 제목
///  - `cwd`       — 작업 디렉터리(로그 위치를 결정하는 값)
///  - `gitBranch` — 브랜치
/// 이 값들로 인덱스를 다시 만들면 목록에 그대로 돌아온다.
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

    /// 인덱스 없는 로그를 찾는다. `minBytes` 미만(빈 껍데기)과 서브에이전트 로그는 제외.
    static func find(folders: [URL], minBytes: Int = 20 * 1024) -> [Found] {
        let fm = FileManager.default
        let indexed = indexedSessionIds(folders: folders)
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

        var title = SessionIndex.scanString(text, key: "aiTitle") ?? SessionIndex.scanString(text, key: "userTitle") ?? ""
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
            obj["titleSource"] = "user"
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
