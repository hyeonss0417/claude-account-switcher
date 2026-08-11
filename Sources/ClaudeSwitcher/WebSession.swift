import Foundation

/// 데스크탑 앱의 **로그인 상태 실체** = Electron 웹세션(쿠키 `sessionKey*` + Local/Session Storage).
/// 계정별로 이 묶음을 통째로 스냅샷/복원하면 데스크탑 로그인 계정이 실제로 바뀐다.
///
/// ⚠️ 반드시 Claude 앱이 **완전히 종료된 상태**에서만 호출할 것 (SQLite 사용 중 복사는 깨진다).
enum WebSession {
    /// 스냅샷 대상: 로그인 상태를 이루는 파일/폴더 (없으면 건너뜀)
    private static var items: [URL] {
        [Paths.cookies, Paths.cookiesJournal, Paths.localStorage, Paths.sessionStorage]
    }

    static func snapshotDir(accountUuid: String) -> URL {
        Paths.appDir.appending(path: "websessions/\(accountUuid)", directoryHint: .isDirectory)
    }

    static func hasSnapshot(accountUuid: String) -> Bool {
        FileManager.default.fileExists(atPath: snapshotDir(accountUuid: accountUuid).appending(path: "Cookies").path)
    }

    /// 현재 웹세션을 해당 계정 스냅샷으로 저장.
    @discardableResult
    static func snapshot(accountUuid: String) -> Bool {
        let fm = FileManager.default
        let dest = snapshotDir(accountUuid: accountUuid)
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            var saved = 0
            for item in items where fm.fileExists(atPath: item.path) {
                try fm.copyItem(at: item, to: dest.appending(path: item.lastPathComponent))
                saved += 1
            }
            Log.info("웹세션 스냅샷 저장 \(accountUuid.prefix(8)) — \(saved)개 항목")
            return saved > 0
        } catch {
            Log.error("웹세션 스냅샷 실패: \(error.localizedDescription)")
            return false
        }
    }

    /// 저장된 스냅샷을 현재 웹세션으로 복원 → 데스크탑 로그인 계정이 바뀐다.
    @discardableResult
    static func restore(accountUuid: String) -> Bool {
        let fm = FileManager.default
        let src = snapshotDir(accountUuid: accountUuid)
        guard fm.fileExists(atPath: src.path) else { return false }
        do {
            var restored = 0
            for item in items {
                let saved = src.appending(path: item.lastPathComponent)
                guard fm.fileExists(atPath: saved.path) else { continue }
                if fm.fileExists(atPath: item.path) { try fm.removeItem(at: item) }
                try fm.copyItem(at: saved, to: item)
                restored += 1
            }
            Log.info("웹세션 복원 \(accountUuid.prefix(8)) — \(restored)개 항목")
            return restored > 0
        } catch {
            Log.error("웹세션 복원 실패: \(error.localizedDescription)")
            return false
        }
    }

    /// 데스크탑 앱이 참조하는 `config.json` 의 현재 계정 표기도 함께 맞춰준다.
    @discardableResult
    static func setDesktopAccount(_ accountUuid: String) -> Bool {
        guard let data = try? Data(contentsOf: Paths.claudeConfig),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        obj["lastKnownAccountUuid"] = accountUuid
        guard let out = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        return (try? out.write(to: Paths.claudeConfig, options: .atomic)) != nil
    }
}
