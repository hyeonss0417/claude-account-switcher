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

    /// 그 데이터 디렉터리가 **어느 계정으로** 로그인돼 있는지(각 인스턴스가 자기 config.json 에 기록).
    /// 스냅샷을 엉뚱한 계정에 씌우는 사고를 막기 위해 반드시 확인한다.
    static func loggedInAccount(dataDir: URL) -> String? {
        let cfg = dataDir.appending(path: "config.json")
        guard let data = try? Data(contentsOf: cfg),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acct = obj["lastKnownAccountUuid"] as? String, UUID(uuidString: acct) != nil else { return nil }
        return acct
    }

    /// 쿠키에 로그인 토큰(`sessionKey*`)이 들어있는지 — 그 데이터 디렉터리가 로그인 상태인가.
    static func isLoggedIn(dataDir: URL) -> Bool {
        let cookies = dataDir.appending(path: "Cookies")
        guard let data = try? Data(contentsOf: cookies) else { return false }
        // SQLite 를 열지 않고도 쿠키 이름은 평문으로 들어있어 존재 확인이 가능하다(값은 암호화됨).
        return data.range(of: Data("sessionKey".utf8)) != nil
    }

    /// 현재 웹세션을 해당 계정 스냅샷으로 저장. `from` 을 주면 그 데이터 디렉터리에서 가져온다
    /// (인스턴스에서 직접 로그인한 경우).
    @discardableResult
    static func snapshot(accountUuid: String, from source: URL? = nil) -> Bool {
        let fm = FileManager.default
        let dest = snapshotDir(accountUuid: accountUuid)
        let sourceItems: [URL] = source.map { root in
            ["Cookies", "Cookies-journal", "Local Storage", "Session Storage"].map { root.appending(path: $0) }
        } ?? items
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            var saved = 0
            for item in sourceItems where fm.fileExists(atPath: item.path) {
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
