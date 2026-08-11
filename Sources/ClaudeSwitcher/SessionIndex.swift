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

    static func load(_ url: URL) -> SessionIndex? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return SessionIndex(
            url: url,
            sessionId: (obj["cliSessionId"] as? String) ?? (obj["sessionId"] as? String),
            cwd: (obj["cwd"] as? String) ?? (obj["originCwd"] as? String),
            title: obj["title"] as? String,
            modified: mtime
        )
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

    /// `~/.claude/projects` 전체를 훑어 sessionId → 로그 경로 인덱스를 만든다(1회 구축 후 재사용).
    static func buildLogIndex() -> [String: URL] {
        var out: [String: URL] = [:]
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: Paths.projectsDir, includingPropertiesForKeys: nil) else { return out }
        for dir in projects {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard size > 0 else { continue }
                out[f.deletingPathExtension().lastPathComponent] = f
            }
        }
        return out
    }
}
