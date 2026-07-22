import Foundation

/// ~/.claude.json 의 oauthAccount 블록에서 뽑아낸 계정 식별 정보.
struct OAuthIdentity: Equatable {
    var accountUuid: String
    var organizationUuid: String
    var emailAddress: String?
    var displayName: String?
    var organizationName: String?
    var organizationRateLimitTier: String?
}

/// 이 앱이 관리하는 계정 프로필. profiles.json 에 영속.
/// 자격증명 원문(토큰)은 여기 저장하지 않고 Keychain(profileService)에 둔다.
struct Profile: Codable, Identifiable {
    var accountUuid: String
    var organizationUuid: String
    var email: String?
    var displayName: String?
    var label: String?              // 사용자가 붙이는 별칭 (선택)
    var rateLimitTier: String?
    /// ~/.claude.json 으로 복원할 oauthAccount 블록 원문(JSON) + userID
    var oauthAccountRaw: Data?
    var userID: String?

    var id: String { accountUuid }

    var displayLabel: String {
        if let l = label, !l.isEmpty { return l }
        if let e = email, !e.isEmpty { return e }
        return String(accountUuid.prefix(8)) + "…"
    }
}
