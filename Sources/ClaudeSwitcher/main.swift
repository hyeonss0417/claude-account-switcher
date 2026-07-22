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
    let n = SessionSync.syncAll(folders: folders)
    print("동기화 완료: \(folders.count)개 폴더에 걸쳐 \(n)개 인덱스 복사")
    exit(0)
}

// 메뉴바 전용 앱(LSUIElement). Dock/메뉴바 없이 상단 status item 만 띄운다.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
