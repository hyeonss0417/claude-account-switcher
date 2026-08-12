import Foundation

struct SyncReport {
    var copied = 0
    var skippedDead = 0      // 대화 로그가 없는 "죽은 인덱스" — 복사하면 빈 세션으로 보인다
    var skippedBusy = 0      // 쓰는 중인 파일
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
    @discardableResult
    static func syncAll(folders: [URL]) -> SyncReport {
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
                if atomicCopy(from: b.index.url, to: folder.appending(path: name)) { report.copied += 1 }
                else { report.failed += 1 }
            }
        } }
        if report.skippedDead > 0 {
            Log.info("동기화: 죽은 인덱스 \(report.skippedDead)개 건너뜀(대화 로그 없음 → 빈 세션 방지)")
        }
        return report
    }

    private static func atomicCopy(from src: URL, to dest: URL) -> Bool {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: src),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return false } // 반쪽 파일 회피
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
