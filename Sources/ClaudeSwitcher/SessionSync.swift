import Foundation

/// 모든 계정/조직 폴더의 local_*.json 을 합집합(union)으로 맞춘다.
/// 세션 인덱스에는 계정 UUID 가 박혀있지 않고(검증됨), 실제 대화 로그는 ~/.claude/projects 에 공유되므로
/// 폴더 간 복사는 안전하다. → 어느 계정으로 로그인하든 동일한 세션 목록이 보인다.
enum SessionSync {
    /// 합집합 동기화. 복사한 파일 수 반환.
    @discardableResult
    static func syncAll(folders: [URL]) -> Int {
        guard folders.count > 1 else { return 0 }
        let fm = FileManager.default

        struct Best { var url: URL; var mtime: Date }
        var best: [String: Best] = [:]                 // basename -> 가장 최근 사본
        var perFolder: [URL: Set<String>] = [:]        // 폴더별 보유 파일명

        for folder in folders {
            var names = Set<String>()
            if let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) {
                for item in items {
                    let name = item.lastPathComponent
                    guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
                    names.insert(name)
                    let mtime = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    if let e = best[name] { if mtime > e.mtime { best[name] = Best(url: item, mtime: mtime) } }
                    else { best[name] = Best(url: item, mtime: mtime) }
                }
            }
            perFolder[folder] = names
        }

        let now = Date()
        var copies = 0
        for (name, b) in best {
            if now.timeIntervalSince(b.mtime) < 3 { continue }   // 쓰는 중인 파일 회피(quiet period)
            for folder in folders where !(perFolder[folder]?.contains(name) ?? false) {
                if atomicCopy(from: b.url, to: folder.appending(path: name)) { copies += 1 }
            }
        }
        return copies
    }

    private static func atomicCopy(from src: URL, to dest: URL) -> Bool {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: src),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return false } // 반쪽 파일 회피
        let tmp = dest.deletingLastPathComponent().appending(path: ".tmp_\(UUID().uuidString)_\(dest.lastPathComponent)")
        do {
            try data.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
            return true
        } catch {
            try? fm.removeItem(at: tmp)
            Log.error("sync copy \(dest.lastPathComponent) 실패: \(error.localizedDescription)")
            return false
        }
    }
}
