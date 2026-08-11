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

// 메뉴바 전용 앱(LSUIElement). Dock/메뉴바 없이 상단 status item 만 띄운다.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
