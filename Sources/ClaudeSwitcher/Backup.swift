import Foundation

/// 전환/동기화 전에 세션 폴더와 ~/.claude.json 을 타임스탬프 백업. 최근 N개만 보관.
enum Backup {
    @discardableResult
    static func snapshotSessions(reason: String) -> URL? {
        Paths.ensureAppDir()
        let fm = FileManager.default
        let dest = Paths.backupsDir.appending(path: "sessions-\(stamp())-\(reason)")
        do {
            try fm.copyItem(at: Paths.sessionsBase, to: dest)
            Log.info("백업(세션) → \(dest.lastPathComponent)")
            prune(prefix: "sessions-", keep: 10)
            return dest
        } catch {
            Log.error("snapshotSessions 실패: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    static func snapshotClaudeJson() -> URL? {
        Paths.ensureAppDir()
        let fm = FileManager.default
        let dest = Paths.backupsDir.appending(path: "claude.json-\(stamp())")
        do { try fm.copyItem(at: Paths.claudeJson, to: dest); prune(prefix: "claude.json-", keep: 10); return dest }
        catch { Log.error("snapshotClaudeJson 실패: \(error.localizedDescription)"); return nil }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    private static func prune(prefix: String, keep: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: Paths.backupsDir, includingPropertiesForKeys: nil) else { return }
        let matching = items.filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // 이름=타임스탬프 → 내림차순
        guard matching.count > keep else { return }
        for old in matching[keep...] { try? fm.removeItem(at: old) }
    }
}
