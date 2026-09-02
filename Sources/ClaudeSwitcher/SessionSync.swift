import Foundation

struct SyncReport {
    var copied = 0
    var skippedDead = 0      // 대화 로그가 없는 "죽은 인덱스" — 복사하면 빈 세션으로 보인다
    var skippedBusy = 0      // 쓰는 중인 파일
    var deferredRunning = 0  // 실행 중인 창이라 나중(종료/재실행 시)으로 미룬 복사
    var failed = 0
}

/// 모든 계정/조직 폴더의 local_*.json 을 합집합(union)으로 맞춘다.
///
/// 세션 인덱스에는 계정 UUID 가 박혀있지 않고(검증됨), 실제 대화 로그는 `~/.claude/projects` 에
/// 계정 무관 공유되므로 폴더 간 복사는 안전하다. → 어느 계정으로 로그인하든 같은 세션 목록이 보인다.
///
/// ⚠️ **핵심 규칙**: 대화 로그(jsonl)가 살아있는 인덱스만 복사한다.
/// worktree 삭제 등으로 로그가 사라진 인덱스를 퍼뜨리면 목록엔 뜨지만 열면 **빈 세션**이 된다.
enum SessionSync {
    /// - Parameter skipWriteTo: **읽기만 하고 쓰지는 않을** 폴더들(=실행 중인 창의 폴더).
    ///
    ///   Claude 는 시작할 때만 세션 폴더를 읽는다. 그래서 실행 중인 창의 폴더에 인덱스를 넣어도
    ///   재시작 전에는 목록에 뜨지 않는다 — **이득은 없고**, 사이드바가 저장소 정보를 다시 해석하는
    ///   동안 같은 프로젝트가 잠깐 두 그룹으로 쪼개졌다 합쳐지는 깜빡임만 생긴다.
    ///   그래서 실행 중인 창에는 쓰지 않고, 그 창이 **종료될 때와 실행되기 직전에** 채운다.
    @discardableResult
    static func syncAll(folders: [URL], skipWriteTo: Set<String> = []) -> SyncReport {
        var report = SyncReport()
        guard folders.count > 1 else { return report }
        let fm = FileManager.default

        // sessionId → 실제 로그 경로 (경로 인코딩이 어긋난 케이스 구제용)
        let logIndex = SessionIndex.buildLogIndex()

        struct Best { var index: SessionIndex }
        var best: [String: Best] = [:]
        var perFolder: [URL: Set<String>] = [:]

        // 파일을 대량으로 읽는 구간 — 오토릴리즈 객체가 쌓이지 않도록 폴더 단위로 풀을 감싼다.
        for folder in folders {
            autoreleasepool {
                var names = Set<String>()
                if let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) {
                    for item in items {
                        let name = item.lastPathComponent
                        guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
                        names.insert(name)
                        guard let idx = SessionIndex.load(item) else { report.failed += 1; continue }
                        if let e = best[name] { if idx.modified > e.index.modified { best[name] = Best(index: idx) } }
                        else { best[name] = Best(index: idx) }
                    }
                }
                perFolder[folder] = names
            }
        }

        let now = Date()
        for (name, b) in best { autoreleasepool {
            // 쓰는 중인 파일 회피
            if now.timeIntervalSince(b.index.modified) < 3 { report.skippedBusy += 1; return }

            // 살아있는 로그가 있는 인덱스만 전파 (빈 세션 확산 방지)
            let alive = b.index.hasLiveLog || b.index.locateLogAnywhere(index: logIndex) != nil
            guard alive else { report.skippedDead += 1; return }

            for folder in folders where !(perFolder[folder]?.contains(name) ?? false) {
                // 실행 중인 창의 폴더는 건너뛴다(위 설명 참고 — 지금 넣어도 안 보이고 깜빡임만 생긴다).
                if skipWriteTo.contains(folder.standardizedFileURL.path) { report.deferredRunning += 1; continue }
                if atomicCopy(from: b.index.url, to: folder.appending(path: name)) { report.copied += 1 }
                else { report.failed += 1 }
            }
        } }
        if report.skippedDead > 0 {
            Log.info("동기화: 죽은 인덱스 \(report.skippedDead)개 건너뜀(대화 로그 없음 → 빈 세션 방지)")
        }
        return report
    }

    /// 인덱스 파일을 복사한다.
    ///
    /// 여기서 JSON 을 다시 파싱하지 않는다 — 호출 전에 `SessionIndex.load` 로 이미 파싱에 성공한
    /// 파일만 넘어오기 때문이다. 파일당 50KB 를 재파싱하면 사본 수천 개를 만들 때 순간 메모리가
    /// GB 단위로 튄다(실측 1.1GB). 대신 반쪽 파일만 값싸게 걸러낸다.
    private static func atomicCopy(from src: URL, to dest: URL) -> Bool {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: src, options: .mappedIfSafe),
              data.count > 2, data.last == UInt8(ascii: "}") else { return false }
        let tmp = dest.deletingLastPathComponent().appending(path: ".tmp_\(UUID().uuidString)_\(dest.lastPathComponent)")
        do {
            try data.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: tmp) }
            else { try fm.moveItem(at: tmp, to: dest) }
            return true
        } catch {
            try? fm.removeItem(at: tmp)
            Log.error("sync copy \(dest.lastPathComponent) 실패: \(error.localizedDescription)")
            return false
        }
    }

    /// 같은 대화(cliSessionId)를 가리키는 인덱스가 여럿이면 하나만 남긴다.
    ///
    /// 왜 생기나: 진행 중 세션은 Claude 가 인덱스를 늦게 쓴다. 그 사이 고아 복구가 사본을 만들고,
    /// 종료 때 Claude 가 자기 인덱스를 마저 쓰면 **같은 세션이 목록에 두 번** 뜬다.
    /// 우선순위: Claude 가 쓴 원본(마커 없음) > 우리 복구본. 단, 원본이 worktree 재활용으로
    /// 가려져 있는 경우(그 worktree 의 최신 세션이 아님)에는 복구본을 남겨야 목록에 보인다.
    @discardableResult
    static func dedupeDuplicates(folders: [URL]) -> Int {
        let fm = FileManager.default
        guard let first = folders.first else { return 0 }
        guard let items = try? fm.contentsOfDirectory(at: first, includingPropertiesForKeys: nil) else { return 0 }

        struct E { let url: URL; let obj: [String: Any] }
        var byCli: [String: [E]] = [:]
        var newestInWorktree: [String: Double] = [:]
        for item in items where item.lastPathComponent.hasPrefix("local_") && item.pathExtension == "json" {
            autoreleasepool {
                guard let data = try? Data(contentsOf: item),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let cli = obj["cliSessionId"] as? String else { return }
                byCli[cli, default: []].append(E(url: item, obj: obj))
                if let wt = obj["worktreeName"] as? String {
                    let ts = (obj["lastActivityAt"] as? Double) ?? 0
                    newestInWorktree[wt] = max(newestInWorktree[wt] ?? 0, ts)
                }
            }
        }

        let dest = Paths.backupsDir.appending(path: "dedup-\(stamp())")
        var removed = 0
        for (_, entries) in byCli where entries.count > 1 {
            let originals = entries.filter { $0.obj["recoveredBy"] == nil }
            let recovered = entries.filter { $0.obj["recoveredBy"] != nil }
            var toRemove: [E] = []
            if let keep = originals.first {
                // 원본이 가려져 있지 않으면 복구본은 전부 제거, 가려져 있으면 복구본 1개는 남긴다.
                let shadowed: Bool = {
                    guard let wt = keep.obj["worktreeName"] as? String,
                          let ts = keep.obj["lastActivityAt"] as? Double else { return false }
                    return (newestInWorktree[wt] ?? 0) > ts
                }()
                toRemove += originals.dropFirst().map { $0 }
                toRemove += shadowed ? recovered.dropFirst().map { $0 } : recovered
            } else {
                toRemove = recovered.dropFirst().map { $0 }     // 전부 복구본이면 1개만 남김
            }
            for e in toRemove {
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                let name = e.url.lastPathComponent
                // 모든 폴더에서 같은 파일명을 치운다(공유 모드에선 첫 폴더가 실체)
                for folder in folders {
                    let f = folder.appending(path: name)
                    guard fm.fileExists(atPath: f.path) else { continue }
                    let backupTarget = dest.appending(path: name)
                    if fm.fileExists(atPath: backupTarget.path) { try? fm.removeItem(at: f) }
                    else if (try? fm.moveItem(at: f, to: backupTarget)) != nil { removed += 1 }
                }
            }
        }
        if removed > 0 { Log.info("중복 세션 정리: \(removed)개 격리") }
        return removed
    }

    /// 이미 퍼진 죽은 인덱스를 백업으로 격리(비파괴). 반환: 격리한 개수.
    @discardableResult
    static func quarantineDeadIndexes(folders: [URL]) -> Int {
        let fm = FileManager.default
        let logIndex = SessionIndex.buildLogIndex()
        let dest = Paths.backupsDir.appending(path: "dead-indexes-\(Self.stamp())")
        var moved = 0
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.lastPathComponent.hasPrefix("local_") && item.pathExtension == "json" {
                guard let idx = SessionIndex.load(item) else { continue }
                if idx.hasLiveLog || idx.locateLogAnywhere(index: logIndex) != nil { continue }
                let sub = dest.appending(path: folder.lastPathComponent)
                try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
                if (try? fm.moveItem(at: item, to: sub.appending(path: item.lastPathComponent))) != nil { moved += 1 }
            }
        }
        if moved > 0 { Log.info("죽은 인덱스 \(moved)개 격리 → \(dest.path)") }
        return moved
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}
