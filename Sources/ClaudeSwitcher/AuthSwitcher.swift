import Foundation
import AppKit

struct SwitchResult {
    var ok: Bool
    var desktopSwitched: Bool    // 데스크탑 로그인까지 실제로 전환됨(웹세션 복원 성공)
    var cliSwitched: Bool        // 터미널 claude(CLI) 계정 전환됨
    var needsGuidedLogin: Bool   // 대상 계정 스냅샷이 없어 최초 1회 수동 로그인 필요
    var message: String
}

/// 계정 전환 오케스트레이션.
///
/// 순서가 중요하다 — **Claude 를 먼저 완전히 종료**해야 웹세션(SQLite)을 안전하게 스냅샷/복원할 수 있다:
///  1) 세션 합집합 동기화 + 백업
///  2) Claude 종료(완전 종료 대기)
///  3) 현재 계정 웹세션 스냅샷 저장 (다음에 돌아올 수 있도록)
///  4) 대상 계정 웹세션 복원 → **데스크탑 로그인 전환**
///  5) CLI 식별(~/.claude.json) + Keychain 자격증명 교체 → **CLI 전환**
///  6) Claude 재기동
enum AuthSwitcher {
    static let claudeBundleId = "com.anthropic.claudefordesktop"

    static func performSwitch(to target: Profile, manager: AccountManager) -> SwitchResult {
        let currentUuid = manager.activeAccountUuid()
        if currentUuid == target.accountUuid {
            return SwitchResult(ok: true, desktopSwitched: false, cliSwitched: false, needsGuidedLogin: false,
                                message: "이미 \(target.displayLabel) 계정입니다.")
        }

        // 1) 백업 + 동기화 (죽은 인덱스는 자동으로 걸러짐)
        Backup.snapshotSessions(reason: "preswitch")
        Backup.snapshotClaudeJson()
        let folders = manager.discoverFolders().map(\.url)
        let report = SessionSync.syncAll(folders: folders)
        Log.info("전환 전 동기화: 복사 \(report.copied), 죽은인덱스 제외 \(report.skippedDead)")

        // 현재 계정의 CLI 식별/자격증명을 먼저 포착 (Keychain 읽기는 이 전환당 최대 1회)
        manager.captureActiveIdentity()
        manager.captureActiveCredential()

        // 2) Claude 완전 종료 (웹세션 파일을 안전하게 다루기 위해 필수)
        quitClaudeAndWait()

        // 3) 현재 웹세션을 현재 계정 스냅샷으로 저장
        if let cur = currentUuid { WebSession.snapshot(accountUuid: cur) }

        // 4) 대상 계정 웹세션 복원 → 데스크탑 로그인 전환
        var desktopSwitched = false
        if WebSession.hasSnapshot(accountUuid: target.accountUuid) {
            desktopSwitched = WebSession.restore(accountUuid: target.accountUuid)
        }
        WebSession.setDesktopAccount(target.accountUuid)

        // 5) CLI 전환
        var cliSwitched = false
        if let cred = Keychain.loadProfileCredential(accountUuid: target.accountUuid),
           let oauthRaw = target.oauthAccountRaw {
            let credOK = Keychain.writeActiveCredential(cred)
            let jsonOK = patchClaudeJson(oauthAccount: oauthRaw, userID: target.userID)
            cliSwitched = credOK && jsonOK
        } else if let oauthRaw = target.oauthAccountRaw {
            cliSwitched = patchClaudeJson(oauthAccount: oauthRaw, userID: target.userID)
        }

        // 6) 재기동
        relaunchClaude()

        let needsLogin = !desktopSwitched
        let msg: String
        if desktopSwitched {
            msg = "\(target.displayLabel) 로 전환 완료 — 데스크탑 로그인까지 적용됨."
        } else {
            msg = "\(target.displayLabel) 준비 완료 — 최초 1회만 Claude 에서 로그인하세요."
        }
        return SwitchResult(ok: true, desktopSwitched: desktopSwitched, cliSwitched: cliSwitched,
                            needsGuidedLogin: needsLogin, message: msg)
    }

    /// 전환 직후(사용자가 대상 계정으로 로그인한 뒤) 그 웹세션을 스냅샷해 두면
    /// 다음부터는 그 계정도 원클릭 전환된다.
    @discardableResult
    static func captureCurrentWebSession(manager: AccountManager) -> Bool {
        guard let cur = manager.activeAccountUuid() else { return false }
        let wasRunning = isClaudeRunning()
        if wasRunning { quitClaudeAndWait() }
        let ok = WebSession.snapshot(accountUuid: cur)
        if wasRunning { relaunchClaude() }
        return ok
    }

    /// ~/.claude.json 의 oauthAccount(+userID)만 교체하고 나머지는 그대로 보존.
    @discardableResult
    static func patchClaudeJson(oauthAccount: Data, userID: String?) -> Bool {
        guard let data = try? Data(contentsOf: Paths.claudeJson),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauthObj = (try? JSONSerialization.jsonObject(with: oauthAccount)) as? [String: Any] else {
            Log.error("patchClaudeJson: 파싱 실패"); return false
        }
        obj["oauthAccount"] = oauthObj
        if let uid = userID { obj["userID"] = uid }
        guard let out = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        do { try out.write(to: Paths.claudeJson, options: .atomic); return true }
        catch { Log.error("patchClaudeJson 쓰기 실패: \(error.localizedDescription)"); return false }
    }

    // MARK: - 앱 제어
    static func isClaudeRunning() -> Bool {
        !NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == claudeBundleId }.isEmpty
    }

    /// 종료 요청 후 실제로 프로세스가 사라질 때까지 대기(최대 ~8초). 안 죽으면 강제 종료.
    ///
    /// ⚠️ 이 함수는 **떠 있는 모든 Claude 창**을 닫는다. 여러 계정을 동시에 쓰는 지금은
    /// 관계없는 창까지 닫히므로, 특정 창만 닫아야 할 때는 `InstanceManager.quitAndWait(pid:)` 를 쓸 것.
    static func quitClaudeAndWait() {
        CrashWatch.markIntentionalQuit()   // 사용자가 지시한 종료 — 사고로 세지 않는다
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == claudeBundleId }
        guard !apps.isEmpty else { return }
        for app in apps { app.terminate() }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if !isClaudeRunning() { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        if isClaudeRunning() {
            Log.info("Claude 정상 종료 실패 → 강제 종료")
            for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == claudeBundleId {
                app.forceTerminate()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        }
        // 파일 핸들 정리 여유
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    static func relaunchClaude() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleId) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
    }
}
