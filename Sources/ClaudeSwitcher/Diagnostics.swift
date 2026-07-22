import Foundation

/// 헤드리스 진단 모드 (`--diagnose`). Keychain·쓰기 없이 현재 상태만 출력.
enum Diagnostics {
    static func run() {
        let m = AccountManager()
        let active = m.activeAccountUuid()
        print("=== Claude Account Switcher — 진단 ===")
        print("세션 베이스: \(Paths.sessionsBase.path)")
        print("활성 계정(UUID): \(active ?? "(판별 실패)")")
        print("  · bridge-state 기준: \(m.bridgeActiveAccount() ?? "-")")
        print("  · ~/.claude.json 기준: \(m.claudeJsonIdentity()?.accountUuid ?? "-")  (\(m.claudeJsonIdentity()?.emailAddress ?? "-"))")
        print("")
        let folders = m.discoverFolders()
        print("발견된 계정 폴더: \(folders.count)")
        for f in folders {
            let n = m.sessionCount(accountUuid: f.accountUuid, orgUuid: f.orgUuid)
            let mark = f.accountUuid == active ? " ← 활성" : ""
            let prof = m.profiles.first { $0.accountUuid == f.accountUuid }
            print("  • \(prof?.displayLabel ?? String(f.accountUuid.prefix(8)))  [\(f.accountUuid.prefix(8))/\(f.orgUuid.prefix(8))]  \(n) 세션\(mark)")
        }
        print("")
        print("프로필(profiles.json): \(m.profiles.count)")
        for p in m.profiles {
            print("  • \(p.displayLabel)  email=\(p.email ?? "-")  tier=\(p.rateLimitTier ?? "-")  oauth복원가능=\(p.oauthAccountRaw != nil)")
        }
    }
}
