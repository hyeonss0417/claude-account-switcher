import Foundation
import Security

/// Keychain 접근. 두 종류:
///  1) `Claude Code-credentials` — Claude 가 현재 로그인한 계정의 OAuth 자격증명(활성). 이 앱이 처음 읽을 때
///     macOS ACL 허용 창이 뜬다 → "항상 허용" 한 번 클릭.
///  2) 이 앱 소유의 프로필별 스냅샷 — 계정마다 자격증명을 따로 보관해 즉시 전환에 사용(프롬프트 없음).
enum Keychain {
    static let claudeService = "Claude Code-credentials"
    static let profileService = "io.github.claudeaccountswitcher.credential"
    static var osAccount: String { NSUserName() }

    /// 현재 활성 Claude 자격증명 읽기. (첫 접근 시 ACL 프롬프트)
    static func readActiveCredential() -> Data? { read(service: claudeService, account: osAccount) }

    /// 활성 Claude 자격증명 덮어쓰기.
    @discardableResult
    static func writeActiveCredential(_ data: Data) -> Bool { upsert(service: claudeService, account: osAccount, data: data) }

    /// 프로필(계정 UUID)별 자격증명 스냅샷 저장 (이 앱 소유, 프롬프트 없음).
    @discardableResult
    static func saveProfileCredential(accountUuid: String, data: Data) -> Bool {
        upsert(service: profileService, account: accountUuid, data: data)
    }
    static func loadProfileCredential(accountUuid: String) -> Data? { read(service: profileService, account: accountUuid) }
    static func hasProfileCredential(accountUuid: String) -> Bool { loadProfileCredential(accountUuid: accountUuid) != nil }

    // MARK: - low level
    private static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecSuccess, let data = out as? Data { return data }
        if status != errSecItemNotFound {
            Log.error("keychain read \(service) status=\(status)")
        }
        return nil
    }

    private static func upsert(service: String, account: String, data: Data) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess { Log.error("keychain add \(service) status=\(addStatus)") }
            return addStatus == errSecSuccess
        }
        Log.error("keychain update \(service) status=\(updateStatus)")
        return false
    }
}
