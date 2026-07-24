import Foundation

/// 모든 파일 경로를 한 곳에서 관리 (DRY). Claude 데스크탑/CLI 가 쓰는 위치 + 이 앱 전용 저장소.
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    // Claude 데스크탑 앱이 쓰는 위치
    static var appSupportClaude: URL {
        home.appending(path: "Library/Application Support/Claude", directoryHint: .isDirectory)
    }
    /// claude-code-sessions/<accountUuid>/<orgUuid>/local_*.json — 계정별 세션 인덱스
    static var sessionsBase: URL {
        appSupportClaude.appending(path: "claude-code-sessions", directoryHint: .isDirectory)
    }
    /// 데스크탑 앱이 자신의 현재 로그인 계정을 기록하는 곳(`lastKnownAccountUuid`).
    /// 계정 메뉴에서 전환하면 갱신됨 → 데스크탑 활성 계정의 가장 신뢰할 만한 신호.
    static var claudeConfig: URL { appSupportClaude.appending(path: "config.json") }
    /// Claude Code 원격 브리지 상태(계정 전환보다 뒤늦게 갱신됨 → 보조 신호).
    static var bridgeState: URL { appSupportClaude.appending(path: "bridge-state.json") }
    /// 등록된 계정 UUID 목록
    static var deviceRegistry: URL { appSupportClaude.appending(path: "ant-device-registry.json") }

    // CLI/공유 식별 정보
    static var claudeJson: URL { home.appending(path: ".claude.json") }

    // 이 앱 전용 저장소 (~/.claude-account-switcher)
    static var appDir: URL {
        home.appending(path: ".claude-account-switcher", directoryHint: .isDirectory)
    }
    static var profilesJson: URL { appDir.appending(path: "profiles.json") }
    static var backupsDir: URL { appDir.appending(path: "backups", directoryHint: .isDirectory) }
    static var logFile: URL { appDir.appending(path: "switcher.log") }

    static func ensureAppDir() {
        let fm = FileManager.default
        try? fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
    }
}
