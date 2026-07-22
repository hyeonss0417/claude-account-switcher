import Foundation
import AppKit

struct SwitchResult {
    var ok: Bool
    var autoApplied: Bool        // 자격증명까지 자동 교체됨
    var needsGuidedLogin: Bool   // 데스크탑에서 수동 로그인 필요
    var message: String
}

/// 계정 전환 오케스트레이션.
/// 1) 현재 계정 포착(복귀용) → 2) 백업 → 3) 세션 합집합 동기화 →
/// 4) [자동] Keychain 자격증명 교체 + ~/.claude.json 패치 → 5) 데스크탑 앱 재기동.
/// 저장된 자격증명이 없으면 4를 건너뛰고 안내(가이드) 로그인으로 폴백.
enum AuthSwitcher {
    static let claudeBundleId = "com.anthropic.claudefordesktop"

    static func performSwitch(to target: Profile, manager: AccountManager) -> SwitchResult {
        if manager.activeAccountUuid() == target.accountUuid {
            return SwitchResult(ok: true, autoApplied: false, needsGuidedLogin: false,
                                message: "이미 \(target.displayLabel) 계정입니다.")
        }

        // 1) 현재 활성 계정 포착 (돌아올 수 있도록)
        manager.captureActiveProfile()

        // 2) 백업
        Backup.snapshotSessions(reason: "preswitch")
        Backup.snapshotClaudeJson()

        // 3) 세션 합집합 동기화 → 대상 계정에서도 전체 세션이 보이게
        let folders = manager.discoverFolders().map(\.url)
        let copied = SessionSync.syncAll(folders: folders)
        Log.info("전환 전 동기화: \(copied)개 인덱스 복사")

        // 4) 자동 자격증명 교체 시도
        var autoApplied = false
        if let cred = Keychain.loadProfileCredential(accountUuid: target.accountUuid),
           let oauthRaw = target.oauthAccountRaw {
            let credOK = Keychain.writeActiveCredential(cred)
            let jsonOK = patchClaudeJson(oauthAccount: oauthRaw, userID: target.userID)
            autoApplied = credOK && jsonOK
            Log.info("자동 교체: cred=\(credOK) json=\(jsonOK)")
        } else {
            Log.info("대상(\(target.displayLabel)) 저장 자격증명 없음 → 가이드 로그인 필요")
        }

        // 5) 데스크탑 앱 재기동
        relaunchClaude()

        if autoApplied {
            return SwitchResult(ok: true, autoApplied: true, needsGuidedLogin: false,
                                message: "\(target.displayLabel) 로 전환. Claude 재기동 중…")
        }
        return SwitchResult(ok: true, autoApplied: false, needsGuidedLogin: true,
                            message: "\(target.displayLabel) 준비 완료. Claude 에서 이 계정으로 로그인하면 마무리됩니다.")
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

    static func relaunchClaude() {
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == claudeBundleId }
        for app in running { app.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleId) else { return }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
        }
    }
}
