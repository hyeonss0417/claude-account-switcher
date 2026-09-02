import Foundation

/// **worktree 재활용으로 가려진 세션**을 찾아 되살린다.
///
/// Claude Code 는 worktree 디렉터리를 재활용한다. 한 worktree 를 여러 세션이 차례로 쓰면
/// 인덱스의 `cwd` 가 전부 같아지고, 데스크탑 목록에는 **그 worktree 의 최신 세션 하나만** 보인다.
/// 나머지는 파일도 로그도 멀쩡한데 목록에서 사라진 것처럼 보인다(동기화 문제가 아니다).
///
/// 복구 방법: 가려진 세션의 대화 로그를 `originCwd`(본체 저장소) 프로젝트 폴더로 복사하고,
/// `cwd` 를 originCwd 로 바꾼 새 인덱스를 기록한다 → worktree 충돌이 풀려 목록에 다시 뜬다.
enum ShadowedSessions {

    struct Shadowed {
        let index: SessionIndex
        let raw: [String: Any]
        let worktreeName: String
        let title: String
    }

    /// 폴더 하나를 기준으로 가려진 세션 목록을 찾는다.
    static func find(in folder: URL) -> [Shadowed] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }

        var byWorktree: [String: [(Double, SessionIndex, [String: Any])]] = [:]
        /// 이미 복구된 세션(cwd==originCwd 인 인덱스)의 대화 로그 id — 중복 복구 방지.
        var alreadyRecovered = Set<String>()

        for f in files where f.lastPathComponent.hasPrefix("local_") && f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let cli = obj["cliSessionId"] as? String,
               let cwd = obj["cwd"] as? String, cwd == (obj["originCwd"] as? String) {
                alreadyRecovered.insert(cli)
            }
            guard let wt = obj["worktreeName"] as? String, !wt.isEmpty,
                  let idx = SessionIndex.load(f) else { continue }
            let ts = (obj["lastActivityAt"] as? Double) ?? 0
            byWorktree[wt, default: []].append((ts, idx, obj))
        }

        var out: [Shadowed] = []
        for (wt, group) in byWorktree where group.count > 1 {
            // 최신 1건은 UI 에 보이므로 제외, 나머지가 가려진 세션
            let sorted = group.sorted { $0.0 > $1.0 }
            for (_, idx, obj) in sorted.dropFirst() {
                // 이미 복구된 것은 건너뜀 (cwd 가 이미 origin 이거나, 복구본이 따로 있는 경우)
                let cwd = obj["cwd"] as? String
                let origin = obj["originCwd"] as? String
                if cwd == origin { continue }
                if let cli = obj["cliSessionId"] as? String, alreadyRecovered.contains(cli) { continue }
                out.append(Shadowed(index: idx, raw: obj, worktreeName: wt,
                                    title: (obj["title"] as? String) ?? "(제목 없음)"))
            }
        }
        return out
    }

    /// 가려진 세션들을 되살린다. 반환: 복구한 개수.
    /// 원본 인덱스와 로그는 **건드리지 않고**, 새 인덱스 + 로그 사본을 만든다(비파괴).
    @discardableResult
    static func unshadow(folders: [URL]) -> Int {
        guard let first = folders.first else { return 0 }
        let fm = FileManager.default
        let targets = find(in: first)
        guard !targets.isEmpty else { return 0 }

        // 로그 인덱스는 한 번만 만든다(루프 안에서 매번 재구축하면 매우 느리다).
        let logIndex = SessionIndex.buildLogIndex()

        var recovered = 0
        for t in targets {
            guard let sid = t.index.sessionId,
                  let origin = t.raw["originCwd"] as? String else { continue }
            // logURL 은 존재 여부와 무관하게 "기대 경로"를 만들어 주므로, 반드시 존재를 확인하고
            // 없으면 전체 인덱스에서 찾아야 한다(경로 인코딩이 어긋난 세션 구제).
            let expected = t.index.logURL
            let srcLog: URL
            if let e = expected, fm.fileExists(atPath: e.path) { srcLog = e }
            else if let found = t.index.locateLogAnywhere(index: logIndex) { srcLog = found }
            else { continue }

            // 1) 로그를 originCwd 프로젝트 폴더로 복사
            let destDir = Paths.projectsDir.appending(path: SessionIndex.encodeProjectDir(origin))
            let destLog = destDir.appending(path: "\(sid).jsonl")
            if !fm.fileExists(atPath: destLog.path) {
                try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                guard (try? fm.copyItem(at: srcLog, to: destLog)) != nil else { continue }
            }

            // 2) worktree 충돌을 푼 새 인덱스를 모든 계정 폴더에 기록
            var obj = t.raw
            let newId = "local_\(UUID().uuidString.lowercased())"
            obj["sessionId"] = newId
            obj["cwd"] = origin
            obj.removeValue(forKey: "worktreePath")
            obj.removeValue(forKey: "worktreeName")
            obj["title"] = "\(t.title) (복구)"
            // 키 정렬: cliSessionId·cwd 가 앞쪽에 와야 헤드 스캔(앞 16KB)이 인식한다.
            // 정렬 없이 쓰면 큰 필드 뒤로 밀려 '인덱스 없음'으로 오판 → 재시작마다 사본이 하나씩 늘었다.
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { continue }
            for folder in folders {
                let p = folder.appending(path: "\(newId).json")
                try? data.write(to: p, options: .atomic)
            }
            recovered += 1
            Log.info("가려진 세션 복구: \(t.title) [worktree \(t.worktreeName)]")
        }
        return recovered
    }
}
