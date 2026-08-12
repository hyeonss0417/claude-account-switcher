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

if cliArgs.contains("--instances") {
    let m = AccountManager()
    let accounts = m.profiles.map(\.accountUuid)
    let list = InstanceManager.list(knownAccounts: accounts)
    print("=== 인스턴스 ===")
    for i in list {
        let label = m.profiles.first { $0.accountUuid == i.accountUuid }?.displayLabel
            ?? (i.accountUuid == InstanceManager.defaultKey ? "기본 창" : String(i.accountUuid.prefix(8)))
        let state = i.isRunning ? "실행 중(pid \(i.pid!))" : "정지"
        let login = i.accountUuid == InstanceManager.defaultKey ? "-"
            : (WebSession.hasSnapshot(accountUuid: i.accountUuid) ? "로그인 저장됨" : "로그인 필요")
        print("  · \(label)  [\(state)]  \(login)")
        print("    dataDir: \(i.dataDir.path)")
    }
    let folders = InstanceManager.allSessionFolders(knownAccounts: accounts)
    print("\n동기화 대상 세션 폴더: \(folders.count)개")
    print("진행 중(잠금 대상) 세션: \(SessionLock.busyCount(folders: folders))개")
    exit(0)
}

if cliArgs.contains("--enforce-lock") {
    let m = AccountManager()
    let folders = InstanceManager.allSessionFolders(knownAccounts: m.profiles.map(\.accountUuid))
    let s = SessionLock.enforce(folders: folders)
    print("잠금 적용: 감춤 \(s.busyHeld)개 / 해제 \(s.released)개")
    exit(0)
}

/// 장시간 동작 시 메모리가 늘어나는지 검증한다(`--stress [횟수]`).
/// 이 앱은 과거에 20시간 동안 수십 GB 를 누수해 머신을 마비시킨 적이 있어, 회귀 확인용으로 남겨둔다.
if cliArgs.contains("--stress") {
    let n = cliArgs.last.flatMap(Int.init) ?? 20
    let m = AccountManager()
    let folders = InstanceManager.allSessionFolders(knownAccounts: m.profiles.map(\.accountUuid))
    func rssMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
    let start = rssMB()
    print("반복 \(n)회 — 시작 RSS \(String(format: "%.1f", start)) MB")
    for i in 1...n {
        autoreleasepool {
            _ = SessionSync.syncAll(folders: folders)
            if Set(folders.map(SessionLock.instanceRoot)).count > 1 {
                _ = SessionLock.enforce(folders: folders)
            }
        }
        if i % 5 == 0 { print("  \(i)회차 RSS \(String(format: "%.1f", rssMB())) MB") }
    }
    let end = rssMB()
    let growth = end - start
    print("종료 RSS \(String(format: "%.1f", end)) MB — 증가 \(String(format: "%+.1f", growth)) MB")
    print(growth < 20 ? "✓ 누수 없음(증가 20MB 미만)" : "✗ 누수 의심 — 회당 \(String(format: "%.2f", growth/Double(n))) MB")
    exit(0)
}

// 메뉴바 전용 앱(LSUIElement). Dock/메뉴바 없이 상단 status item 만 띄운다.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
