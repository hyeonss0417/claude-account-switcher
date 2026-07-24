import Foundation

/// 계정 발견 · 활성 계정 판별 · 프로필 영속 · 세션 수 카운트를 담당.
final class AccountManager {
    private(set) var profiles: [Profile] = []
    private let fm = FileManager.default

    init() {
        Paths.ensureAppDir()
        load()
        refreshFromDisk()
    }

    // MARK: - 영속
    private func load() {
        guard let data = try? Data(contentsOf: Paths.profilesJson),
              let decoded = try? JSONDecoder().decode([Profile].self, from: data)
        else { profiles = []; return }
        profiles = decoded
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(profiles) {
            try? data.write(to: Paths.profilesJson, options: .atomic)
        }
    }

    // MARK: - 계정 폴더 발견
    struct FolderRef { let accountUuid: String; let orgUuid: String; let url: URL }

    func discoverFolders() -> [FolderRef] {
        var out: [FolderRef] = []
        guard let accounts = try? fm.contentsOfDirectory(at: Paths.sessionsBase,
                                                         includingPropertiesForKeys: [.isDirectoryKey]) else { return out }
        for acct in accounts {
            let acctId = acct.lastPathComponent
            guard isUuid(acctId),
                  (try? acct.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let orgs = try? fm.contentsOfDirectory(at: acct, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for org in orgs where isUuid(org.lastPathComponent) {
                out.append(FolderRef(accountUuid: acctId, orgUuid: org.lastPathComponent, url: org))
            }
        }
        return out
    }

    func sessionCount(accountUuid: String, orgUuid: String) -> Int {
        let dir = Paths.sessionsBase.appending(path: accountUuid).appending(path: orgUuid)
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        return items.filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }.count
    }

    // MARK: - 활성 계정 판별
    /// 우선순위:
    ///  1) config.json `lastKnownAccountUuid` — 데스크탑 앱이 계정 메뉴 전환 시 바로 갱신(가장 정확).
    ///  2) bridge-state.json — Claude Code 원격 브리지(전환보다 뒤늦게 갱신).
    ///  3) ~/.claude.json — CLI 세션이 실제로 돌 때만 갱신(가장 느림).
    /// 데스크탑 UI 에서 계정을 바꾸면 2·3 은 한동안 옛 계정을 가리키므로 1 을 최우선으로 본다.
    func activeAccountUuid() -> String? {
        desktopActiveAccount() ?? bridgeActiveAccount() ?? claudeJsonIdentity()?.accountUuid
    }

    /// 데스크탑 앱이 config.json 에 기록하는 현재 로그인 계정.
    func desktopActiveAccount() -> String? {
        guard let data = try? Data(contentsOf: Paths.claudeConfig),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acct = obj["lastKnownAccountUuid"] as? String, isUuid(acct) else { return nil }
        return acct
    }

    func bridgeActiveAccount() -> String? {
        guard let data = try? Data(contentsOf: Paths.bridgeState),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // 키 형식: "<orgUuid>:<accountUuid>"
        func accountPart(_ key: String) -> String? {
            let parts = key.split(separator: ":")
            return parts.count == 2 ? String(parts[1]) : nil
        }
        for (key, val) in obj {
            if let dict = val as? [String: Any], (dict["enabled"] as? Bool) ?? false,
               let a = accountPart(key) { return a }
        }
        if let key = obj.keys.first { return accountPart(key) }
        return nil
    }

    // MARK: - ~/.claude.json 식별 정보
    func claudeJsonIdentity() -> OAuthIdentity? {
        guard let obj = readClaudeJsonObject(),
              let oauth = obj["oauthAccount"] as? [String: Any],
              let acct = oauth["accountUuid"] as? String,
              let org = oauth["organizationUuid"] as? String else { return nil }
        return OAuthIdentity(
            accountUuid: acct,
            organizationUuid: org,
            emailAddress: oauth["emailAddress"] as? String,
            displayName: oauth["displayName"] as? String,
            organizationName: oauth["organizationName"] as? String,
            organizationRateLimitTier: oauth["organizationRateLimitTier"] as? String
        )
    }

    /// 복원용 원문(oauthAccount 블록 + top-level userID).
    func claudeJsonRawIdentity() -> (oauthAccount: Data, userID: String?)? {
        guard let obj = readClaudeJsonObject(),
              let oauth = obj["oauthAccount"] as? [String: Any],
              let raw = try? JSONSerialization.data(withJSONObject: oauth) else { return nil }
        return (raw, obj["userID"] as? String)
    }

    private func readClaudeJsonObject() -> [String: Any]? {
        guard let data = try? Data(contentsOf: Paths.claudeJson) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - 갱신 / 시드
    func refreshFromDisk() {
        // 발견된 폴더마다 프로필 보장
        for f in discoverFolders() where !profiles.contains(where: { $0.accountUuid == f.accountUuid }) {
            profiles.append(Profile(accountUuid: f.accountUuid, organizationUuid: f.orgUuid,
                                    email: nil, displayName: nil, label: nil, rateLimitTier: nil,
                                    oauthAccountRaw: nil, userID: nil))
        }
        captureActiveIdentity()   // oauthAccountRaw 포함 식별 정보 갱신 (Keychain 접근 없음)
        save()
    }

    private func upsertIdentity(_ id: OAuthIdentity) {
        if let idx = profiles.firstIndex(where: { $0.accountUuid == id.accountUuid }) {
            profiles[idx].organizationUuid = id.organizationUuid
            if let e = id.emailAddress { profiles[idx].email = e }
            if let d = id.displayName { profiles[idx].displayName = d }
            if let t = id.organizationRateLimitTier { profiles[idx].rateLimitTier = t }
        } else {
            profiles.append(Profile(accountUuid: id.accountUuid, organizationUuid: id.organizationUuid,
                                    email: id.emailAddress, displayName: id.displayName, label: nil,
                                    rateLimitTier: id.organizationRateLimitTier, oauthAccountRaw: nil, userID: nil))
        }
    }

    /// 활성 계정의 식별 정보(oauthAccount 블록 + userID)를 포착. **Keychain 접근 없음 → 프롬프트 없음.**
    /// 앱 시작·메뉴 갱신마다 호출해도 안전(빠름).
    @discardableResult
    func captureActiveIdentity() -> Bool {
        guard let id = claudeJsonIdentity() else { return false }
        upsertIdentity(id)
        if let raw = claudeJsonRawIdentity(), let idx = profiles.firstIndex(where: { $0.accountUuid == id.accountUuid }) {
            profiles[idx].oauthAccountRaw = raw.oauthAccount
            profiles[idx].userID = raw.userID
        }
        save()
        return true
    }

    /// 활성 계정의 Keychain 자격증명을 프로필 스냅샷으로 저장. **여기서 ACL 허용 창이 뜬다.**
    /// 전환 직전이나 사용자가 명시적으로 「현재 계정 포착」을 누를 때만 호출.
    @discardableResult
    func captureActiveCredential() -> Bool {
        guard let id = claudeJsonIdentity() else {
            Log.error("captureActiveCredential: ~/.claude.json 에 oauthAccount 없음"); return false
        }
        guard let cred = Keychain.readActiveCredential() else {
            Log.error("captureActiveCredential: Keychain 자격증명 읽기 실패"); return false
        }
        let ok = Keychain.saveProfileCredential(accountUuid: id.accountUuid, data: cred)
        Log.info("자격증명 포착 \(id.emailAddress ?? id.accountUuid): \(ok)")
        return ok
    }

    /// 식별 정보 + 자격증명 모두 포착(전환/명시적 포착용).
    @discardableResult
    func captureActiveProfile() -> Bool {
        let idOK = captureActiveIdentity()
        let credOK = captureActiveCredential()
        return idOK && credOK
    }

    private func isUuid(_ s: String) -> Bool { UUID(uuidString: s) != nil }
}
