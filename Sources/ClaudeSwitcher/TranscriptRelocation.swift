import Foundation

/// **worktree 가 바뀌며 대화 로그가 옮겨간 세션**의 인덱스를 로그가 실제로 있는 곳으로 다시 잇는다.
///
/// Claude 는 세션을 재개할 때 그 세션의 worktree 가 다른 브랜치로 넘어가 있으면 다른 worktree 를
/// 빌려 쓰고, 대화 로그를 새 worktree 의 프로젝트 폴더로 **옮긴다**(main.log: "Migrated transcript …",
/// "re-leased …"). 옮긴 창은 인덱스의 cwd 를 새 worktree 로 고쳐 저장한다.
///
/// 문제는 다른 창이다. Claude 는 세션 목록을 시작할 때만 읽으므로, 그 전에 떠 있던 창은 옛 cwd 를
/// 메모리에 들고 있다. 거기서 그 세션에 메시지를 보내면 옛 폴더에 로그가 없으니 **빈 대화로 새로
/// 시작**하고(같은 세션 id 의 짧은 로그가 옛 폴더에 생긴다), 그 창이 옛 cwd 로 인덱스를 다시 저장한다.
/// 그게 가장 최신이라 동기화가 모든 창에 퍼뜨린다 → 어느 창에서 열어도 대화가 비어 보인다.
/// (실측 2026-10-14: "짐워크 종목 정규화 및 중복 제거" — 본문 15MB 는 새 worktree 폴더에 멀쩡히 있었고,
/// 인덱스는 마지막 프롬프트 한 줄만 든 옛 폴더의 로그를 가리키고 있었다.)
///
/// 판별: 같은 세션 id 의 로그가 여러 프로젝트 폴더에 있을 때 **가장 큰 것이 본문**이다. 인덱스가
/// 가리키는 로그가 없거나 본문보다 훨씬 작으면, 본문 로그 안에 기록된 cwd 중 그 폴더 이름과
/// 맞는 경로로 인덱스의 cwd·worktreePath·worktreeName 을 고친다.
enum TranscriptRelocation {

    struct Fix {
        let file: String
        let title: String
        let from: String
        let to: String
    }

    /// - Returns: 고친 인덱스 파일 수(모든 폴더 합).
    @discardableResult
    static func repair(folders: [URL], dryRun: Bool = false) -> [Fix] {
        let fm = FileManager.default
        let logs = allLogs()                      // 세션 id → 그 id 의 로그들
        var fixes: [Fix] = []
        var cwdCache: [String: String?] = [:]     // 본문 로그 경로 → 고칠 cwd

        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.lastPathComponent.hasPrefix("local_") && item.pathExtension == "json" {
                autoreleasepool {
                    guard let idx = SessionIndex.load(item), let sid = idx.sessionId, let cwd = idx.cwd,
                          let copies = logs[sid], !copies.isEmpty else { return }
                    let main = copies.max { $0.size < $1.size }!
                    guard main.size >= 64 * 1024 else { return }
                    let expectedDir = SessionIndex.encodeProjectDir(cwd)
                    if main.dir == expectedDir { return }                       // 이미 본문을 가리킨다
                    let pointed = copies.first { $0.dir == expectedDir }?.size ?? 0
                    guard pointed * 4 < main.size else { return }               // 가리키는 쪽도 충분히 크면 판단 보류

                    // Claude 가 로그를 옮기는 건 worktree 세션이 다른 worktree 를 빌렸을 때뿐이다.
                    // worktree ↔ 저장소 루트 같은 이동은 다루지 않는다(세션이 메인 체크아웃에서 작업하게 된다).
                    guard cwd.contains("/.claude/worktrees/") else { return }
                    let newCwd: String? = cwdCache[main.url.path] ?? {
                        let v = cwdMatching(dir: main.dir, in: main.url)
                        cwdCache[main.url.path] = v
                        return v
                    }()
                    guard let newCwd, newCwd.contains("/.claude/worktrees/"), fm.fileExists(atPath: newCwd) else { return }

                    guard let data = try? Data(contentsOf: item),
                          var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                    // 새 worktree 가 정말 이 세션 것인지: 그 세션의 브랜치가 거기 체크아웃돼 있어야 한다.
                    guard let branch = obj["branch"] as? String, !branch.isEmpty,
                          checkedOutBranch(at: newCwd) == branch else { return }
                    obj["cwd"] = newCwd
                    obj["worktreePath"] = newCwd
                    obj["worktreeName"] = URL(fileURLWithPath: newCwd).lastPathComponent
                    fixes.append(Fix(file: item.lastPathComponent, title: (obj["title"] as? String) ?? sid,
                                     from: cwd, to: newCwd))
                    if dryRun { return }
                    backup(item)
                    // 키 정렬: cliSessionId·cwd 가 앞 16KB 안에 와야 헤드 스캔이 읽는다.
                    if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
                        try? out.write(to: item, options: .atomic)      // mtime 이 최신이 되어 동기화가 이 판을 퍼뜨린다
                    }
                }
            }
        }
        if !fixes.isEmpty, !dryRun {
            let titles = Set(fixes.map(\.title)).sorted().prefix(5).joined(separator: ", ")
            Log.info("옮겨간 대화 로그에 인덱스 재연결: 파일 \(fixes.count)개 — \(titles)")
        }
        return fixes
    }

    // MARK: - 내부

    struct LogCopy { let url: URL; let dir: String; let size: Int }

    /// `~/.claude/projects/*/*.jsonl` 를 세션 id 별로 모은다.
    private static func allLogs() -> [String: [LogCopy]] {
        let fm = FileManager.default
        var out: [String: [LogCopy]] = [:]
        guard let projects = try? fm.contentsOfDirectory(at: Paths.projectsDir, includingPropertiesForKeys: nil) else { return out }
        for dir in projects {
            autoreleasepool {
                guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return }
                for f in files where f.pathExtension == "jsonl" {
                    let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    guard size > 0 else { continue }
                    out[f.deletingPathExtension().lastPathComponent, default: []]
                        .append(LogCopy(url: f, dir: dir.lastPathComponent, size: size))
                }
            }
        }
        return out
    }

    /// 로그에 기록된 cwd 값 중 프로젝트 폴더 이름(인코딩)과 맞는 것. 끝에서부터 찾는다.
    private static func cwdMatching(dir: String, in log: URL) -> String? {
        guard let data = try? Data(contentsOf: log, options: .mappedIfSafe) else { return nil }
        let key = Data("\"cwd\":\"".utf8)
        var end = data.endIndex
        var checked = 0
        while checked < 20_000, let r = data.range(of: key, options: .backwards, in: data.startIndex..<end) {
            checked += 1
            end = r.lowerBound
            guard let q = data[r.upperBound...].firstIndex(of: UInt8(ascii: "\"")) else { continue }
            let value = String(decoding: data[r.upperBound..<q], as: UTF8.self)
            if SessionIndex.encodeProjectDir(value) == dir { return value }
        }
        return nil
    }

    /// worktree 에 체크아웃된 브랜치 이름. git 을 띄우지 않고 `.git` 파일 → gitdir/HEAD 를 읽는다.
    static func checkedOutBranch(at worktree: String) -> String? {
        let dotGit = URL(fileURLWithPath: worktree).appending(path: ".git")
        var headURL = dotGit.appending(path: "HEAD")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir: ") }) else { return nil }
            var gitdir = String(line.dropFirst("gitdir: ".count)).trimmingCharacters(in: .whitespaces)
            if !gitdir.hasPrefix("/") { gitdir = URL(fileURLWithPath: worktree).appending(path: gitdir).standardizedFileURL.path }
            headURL = URL(fileURLWithPath: gitdir).appending(path: "HEAD")
        }
        guard let head = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
        let t = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("ref: refs/heads/") else { return nil }
        return String(t.dropFirst("ref: refs/heads/".count))
    }

    private static func backup(_ item: URL) {
        let fm = FileManager.default
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let dest = Paths.backupsDir.appending(path: "relink-\(f.string(from: Date()))")
            .appending(path: Paths.backupKey(for: item.deletingLastPathComponent()))
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let target = dest.appending(path: item.lastPathComponent)
        if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: item, to: target) }
    }
}
