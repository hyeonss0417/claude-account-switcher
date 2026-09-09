import Foundation

/// **공유 폴더 모드의 잔재 정리.**
///
/// 예전엔 계정·인스턴스별 `<acct>/<org>` 폴더를 전부 하나의 실체(`shared-sessions`)로 향하는
/// 심볼릭 링크로 바꿔 아카이브 같은 상태 변경을 전파했다. Claude 1.49585.0(2026-09-08)부터는
/// 세션 저장 경로에 링크가 끼어 있으면 쓰기를 거부한다 — main.log 에
/// `Failed to save session …: ENOTDIR` 가 남고, 번들 안 검사 문구는
/// "symlink at a non-leaf component below the co-writable boundary" 다.
/// 그 뒤로 어느 창도 제목·아카이브 변경을 저장하지 못했고, 새 세션은 인덱스 없이 로그만 남았다.
/// 그래서 링크를 실제 폴더로 되돌리고, 상태 전파는 최신본 우선 복사(SessionSync)로 한다.
enum LinkMode {
    /// 예전 공유 실체. 되돌릴 때 여기 내용으로 각 폴더를 채운다.
    static var canonical: URL {
        Paths.appDir.appending(path: "shared-sessions", directoryHint: .isDirectory)
    }

    static func isLinked(_ folder: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.path)) != nil
    }

    /// 창이 실제로 쓰는 폴더들: 기본 인스턴스와 계정 인스턴스의 `<acct>/<org>`.
    static func foldersInUse(profiles: [Profile]) -> Set<String> {
        var out = Set<String>()
        for p in profiles where !p.organizationUuid.isEmpty {
            out.insert(Paths.sessionsBase.appending(path: p.accountUuid)
                .appending(path: p.organizationUuid).standardizedFileURL.path)
            out.insert(InstanceManager.dataDir(for: p.accountUuid).appending(path: "claude-code-sessions")
                .appending(path: p.accountUuid).appending(path: p.organizationUuid).standardizedFileURL.path)
        }
        return out
    }

    /// 링크로 남아 있는 세션 폴더를 실제 폴더로 되돌린다.
    /// - `keep` 에 든 폴더는 실체 내용을 복사해 채운다(APFS 클론이라 디스크는 거의 안 든다).
    ///   그 밖의 링크(다른 계정 폴더가 잘못 끼어든 것)는 지운다 — 필요하면 Claude 가 다시 만든다.
    /// - **실행 중인 창의 폴더도 되돌린다.** 링크인 채로는 그 창의 저장이 전부 실패하므로 놔두는 쪽이 더 해롭다.
    /// - Returns: 되돌린 폴더 수(링크가 없으면 0 — 매 사이클 불러도 비용이 없다).
    @discardableResult
    static func restoreRealFolders(rawFolders: [URL], keep: Set<String>) -> Int {
        let fm = FileManager.default
        var restored = 0
        for folder in rawFolders where isLinked(folder) {
            guard unlink(folder.path) == 0 else {           // 링크만 지운다(실체는 그대로)
                Log.error("링크 제거 실패 \(folder.lastPathComponent)"); continue
            }
            restored += 1
            guard keep.contains(folder.standardizedFileURL.path) else { continue }
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let items = (try? fm.contentsOfDirectory(at: canonical, includingPropertiesForKeys: nil)) ?? []
                var n = 0
                for item in items where item.lastPathComponent.hasPrefix("local_") && item.pathExtension == "json" {
                    if (try? fm.copyItem(at: item, to: folder.appending(path: item.lastPathComponent))) != nil { n += 1 }
                }
                Log.info("링크 → 실제 폴더 복원: \(folder.deletingLastPathComponent().lastPathComponent.prefix(8))/\(folder.lastPathComponent.prefix(8)) (\(n)개)")
            } catch {
                Log.error("폴더 복원 실패 \(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return restored
    }
}
