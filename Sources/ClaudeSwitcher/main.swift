import AppKit

// 헤드리스 서브커맨드 (GUI 없이 검증/디버그용)
let cliArgs = CommandLine.arguments
if cliArgs.contains("--diagnose") {
    Diagnostics.run()
    exit(0)
}
if cliArgs.contains("--sync") {
    let m = AccountManager()
    let folders = m.discoverFolders().map(\.url)
    let r = SessionSync.syncAll(folders: folders)
    print("동기화 완료: 폴더 \(folders.count)개")
    print("  복사: \(r.copied)")
    print("  죽은 인덱스 제외(빈 세션 방지): \(r.skippedDead)")
    print("  쓰는중 건너뜀: \(r.skippedBusy)   실패: \(r.failed)")
    exit(0)
}

if cliArgs.contains("--clean-dead") {
    let m = AccountManager()
    let folders = m.discoverFolders().map(\.url)
    let n = SessionSync.quarantineDeadIndexes(folders: folders)
    print("빈 세션(죽은 인덱스) \(n)개를 백업 폴더로 격리했습니다.")
    for f in folders {
        let c = (try? FileManager.default.contentsOfDirectory(atPath: f.path))?
            .filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }.count ?? 0
        print("  \(f.deletingLastPathComponent().lastPathComponent.prefix(8))/\(f.lastPathComponent.prefix(8)): \(c)")
    }
    exit(0)
}

if cliArgs.contains("--find-shadowed") || cliArgs.contains("--unshadow") {
    let m = AccountManager()
    let folders = m.discoverFolders().map(\.url)
    guard let first = folders.first else { print("계정 폴더 없음"); exit(1) }
    let found = ShadowedSessions.find(in: first)
    print("worktree 재활용으로 가려진 세션: \(found.count)개")
    for s in found.prefix(30) { print("  · \(s.title)   [worktree \(s.worktreeName)]") }
    if cliArgs.contains("--unshadow") {
        let n = ShadowedSessions.unshadow(folders: folders)
        print("\n복구 완료: \(n)개 (원본은 그대로, 새 항목으로 추가)")
        print("→ Claude 를 재시작하면 목록에 나타납니다.")
    } else {
        print("\n복구하려면: --unshadow")
    }
    exit(0)
}

// 메뉴바 전용 앱(LSUIElement). Dock/메뉴바 없이 상단 status item 만 띄운다.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
