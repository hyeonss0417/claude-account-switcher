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
    /// 세션의 마지막 활동 시각(ms). 잠금에서 "소유 인스턴스" 판별에 쓴다.
    var lastActivity: Double = 0

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

    /// 헤드에서 읽어들일 크기. 필요한 키(sessionId·cliSessionId·cwd·originCwd·title …)는 모두
    /// 파일 앞쪽에 몰려 있어 이 정도면 충분하다. 못 찾으면 전체 파싱으로 폴백한다.
    private static let headBytes = 16 * 1024

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

        // 인덱스 파일은 평균 250KB 나 되고 수천 개다. 전체를 JSONSerialization 으로 파싱하면
        // 객체 그래프가 파일당 수 MB 로 부풀어, 한 사이클에 힙이 1GB 까지 치솟는다(실측).
        // 필요한 값은 문자열 몇 개뿐이므로 **앞부분만 읽어 키를 직접 스캔**한다.
        var result: SessionIndex?
        autoreleasepool {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            guard let head = try? handle.read(upToCount: headBytes), !head.isEmpty else { return }
            let text = String(decoding: head, as: UTF8.self)

            let cli = Self.scanString(text, key: "cliSessionId")
            let sid = Self.scanString(text, key: "sessionId")
            let cwd = Self.scanString(text, key: "cwd")
            let origin = Self.scanString(text, key: "originCwd")
            let title = Self.scanString(text, key: "title")

            // cliSessionId 는 로그 파일명과 같은 진짜 세션 id 다. 헤드에 없으면(키가 뒤로 밀린 파일)
            // 반드시 전체 파싱으로 확인해야 한다 — 안 그러면 sessionId(local_…)를 대신 써서
            // '인덱스 없음'으로 오판하고 고아 복구가 사본을 계속 만든다.
            guard cli != nil, (cwd ?? origin) != nil else { return }   // 못 찾으면 폴백
            result = SessionIndex(url: url, sessionId: cli ?? sid,
                                  cwd: cwd ?? origin, title: title, modified: mtime,
                                  lastActivity: Self.scanNumber(text, key: "lastActivityAt") ?? 0)
        }
        if result == nil {
            // 폴백: 드물게 헤드에 없으면 전체 파싱
            autoreleasepool {
                guard let data = try? Data(contentsOf: url),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                result = SessionIndex(
                    url: url,
                    sessionId: (obj["cliSessionId"] as? String) ?? (obj["sessionId"] as? String),
                    cwd: (obj["cwd"] as? String) ?? (obj["originCwd"] as? String),
                    title: obj["title"] as? String,
                    modified: mtime,
                    lastActivity: (obj["lastActivityAt"] as? Double) ?? 0)
            }
        }
        if let r = result {
            parseLock.lock()
            if parseCache.count > 8000 { parseCache.removeAll(keepingCapacity: true) }  // 폭주 방지
            parseCache[key] = CacheEntry(mtime: mtime, size: size, index: r)
            parseLock.unlock()
        }
        return result
    }

    /// `"key":"value"` 형태의 문자열 값을 찾아낸다(이스케이프가 없는 단순 값 기준).
    /// JSON 전체를 객체로 만들지 않기 위한 가벼운 스캐너다.
    static func scanString(_ text: String, key: String) -> String? {
        guard let r = text.range(of: "\"\(key)\":\"") else { return nil }
        let rest = text[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<end])
        return value.isEmpty ? nil : value
    }

    /// `"key":123` 형태의 숫자 값.
    static func scanNumber(_ text: String, key: String) -> Double? {
        guard let r = text.range(of: "\"\(key)\":") else { return nil }
        let rest = text[r.upperBound...].prefix(32)
        let digits = rest.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(digits)
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
