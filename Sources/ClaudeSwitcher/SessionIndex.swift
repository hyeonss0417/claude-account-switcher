import Foundation

/// 세션 인덱스(local_*.json) 한 건과, 그것이 가리키는 **실제 대화 로그(jsonl)** 의 존재 여부.
///
/// 배경: 인덱스는 `~/.claude/projects/<인코딩된 cwd>/<sessionId>.jsonl` 을 가리키는 포인터일 뿐이다.
/// worktree 가 삭제·재활용되면 로그 폴더가 통째로 사라져 **인덱스만 남은 "죽은 세션"** 이 된다.
/// 이걸 다른 계정으로 복사하면 목록에는 보이지만 열면 대화가 비어 있다 → 동기화에서 걸러내야 한다.
struct SessionIndex {
    let url: URL
    let sessionId: String?
    let cwd: String?
    let title: String?
    let modified: Date

    /// `~/.claude/projects` 폴더명 인코딩 규칙: 영숫자와 `-` 를 제외한 모든 문자를 `-` 로 치환.
    /// (`/`, `.`, `_`, 공백, 한글 등 전부 해당 — 실측으로 확인된 규칙)
    static func encodeProjectDir(_ path: String) -> String {
        String(path.map { ch in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "-" ? ch : "-"
        })
    }

    /// 파싱 결과 캐시. 인덱스 파일 하나가 50KB 안팎이고 수천 개라, 동기화마다 전부 다시 파싱하면
    /// 한 번에 수백 MB 를 잡아먹는다. **파일이 바뀌지 않았으면(mtime·size 동일) 다시 읽지 않는다.**
    private struct CacheEntry { let mtime: Date; let size: Int; let index: SessionIndex }
    private static var parseCache: [String: CacheEntry] = [:]
    private static let parseLock = NSLock()

    static func load(_ url: URL) -> SessionIndex? {
        let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = vals?.contentModificationDate ?? .distantPast
        let size = vals?.fileSize ?? -1
        let key = url.path

        parseLock.lock()
        if let hit = parseCache[key], hit.mtime == mtime, hit.size == size {
            parseLock.unlock()
            return hit.index
        }
        parseLock.unlock()

        // 파일 단위로 풀을 감싸 파싱 중간 산물이 즉시 회수되게 한다.
        var result: SessionIndex?
        autoreleasepool {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            result = SessionIndex(
                url: url,
                sessionId: (obj["cliSessionId"] as? String) ?? (obj["sessionId"] as? String),
                cwd: (obj["cwd"] as? String) ?? (obj["originCwd"] as? String),
                title: obj["title"] as? String,
                modified: mtime
            )
        }
        if let r = result {
            parseLock.lock()
            if parseCache.count > 8000 { parseCache.removeAll(keepingCapacity: true) }  // 폭주 방지
            parseCache[key] = CacheEntry(mtime: mtime, size: size, index: r)
            parseLock.unlock()
        }
        return result
    }

    /// 이 인덱스가 가리키는 대화 로그 경로(기대 위치).
    var logURL: URL? {
        guard let sessionId, let cwd else { return nil }
        return Paths.projectsDir
            .appending(path: Self.encodeProjectDir(cwd))
            .appending(path: "\(sessionId).jsonl")
    }

    /// 대화 로그가 실제로 존재하고 비어있지 않은가. (동기화 대상 판별 기준)
    var hasLiveLog: Bool {
        guard let logURL else { return false }
        guard let vals = try? logURL.resourceValues(forKeys: [.fileSizeKey]) else { return false }
        return (vals.fileSize ?? 0) > 0
    }

    /// 기대 위치엔 없지만 다른 프로젝트 폴더에 같은 sessionId 로그가 있는 경우를 찾는다.
    /// (한글 경로·worktree 이름 변경 등으로 cwd 와 실제 폴더가 어긋난 케이스 구제)
    func locateLogAnywhere(index: [String: URL]) -> URL? {
        guard let sessionId else { return nil }
        return index[sessionId]
    }

    // MARK: - 캐시
    // `~/.claude/projects` 전수 스캔은 수천 개 파일을 훑기 때문에 매우 비싸다.
    // 동기화마다 다시 만들면 메모리·I/O 가 폭주하므로 짧게 캐시한다.
    private static var logIndexCache: [String: URL] = [:]
    private static var logIndexBuiltAt: Date = .distantPast
    private static let logIndexTTL: TimeInterval = 120
    private static let cacheLock = NSLock()

    /// `~/.claude/projects` 전체를 훑어 sessionId → 로그 경로 인덱스를 만든다(TTL 캐시).
    static func buildLogIndex() -> [String: URL] {
        cacheLock.lock()
        if Date().timeIntervalSince(logIndexBuiltAt) < logIndexTTL, !logIndexCache.isEmpty {
            let cached = logIndexCache
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var out: [String: URL] = [:]
        autoreleasepool {
            let fm = FileManager.default
            guard let projects = try? fm.contentsOfDirectory(at: Paths.projectsDir, includingPropertiesForKeys: nil) else { return }
            out.reserveCapacity(4096)
            for dir in projects {
                autoreleasepool {
                    guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return }
                    for f in files where f.pathExtension == "jsonl" {
                        let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                        guard size > 0 else { continue }
                        out[f.deletingPathExtension().lastPathComponent] = f
                    }
                }
            }
        }
        cacheLock.lock()
        logIndexCache = out
        logIndexBuiltAt = Date()
        cacheLock.unlock()
        return out
    }

    /// 캐시를 비운다(동기화 한 사이클이 끝날 때 호출 — 메모리를 오래 붙들지 않기 위해).
    static func flushCaches() {
        cacheLock.lock()
        logIndexCache.removeAll(keepingCapacity: false)
        logIndexBuiltAt = .distantPast
        cacheLock.unlock()
    }
}
