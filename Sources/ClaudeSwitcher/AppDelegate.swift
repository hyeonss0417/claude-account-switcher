import AppKit
import Foundation
import ServiceManagement

/// 상단 메뉴바 아이콘 + 메뉴 구성 + 백그라운드 세션 동기화.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let manager = AccountManager()
    private var syncTimer: Timer?
    private var autoSync = true
    private var watcher: FolderWatcher?
    private var lifecycleObserved = false

    /// 메뉴바가 꽉 차서 상태 아이콘을 누르기 어려울 때를 위한 Dock 아이콘 표시 옵션.
    private static let dockIconKey = "showDockIcon"
    private var showDockIcon: Bool {
        get { UserDefaults.standard.bool(forKey: Self.dockIconKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.dockIconKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensureAppDir()
        Log.info("앱 시작")
        applyActivationPolicy()

        // 아이콘·메뉴를 먼저 띄운다(즉시 표시). 식별 정보 포착은 Keychain 접근이 없어 프롬프트가 없다.
        // 자격증명 포착(Keychain 허용 창)은 실제 전환/명시적 포착 때만 발생 → 시작이 막히지 않는다.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: "Claude Account Switcher")
            button.image?.isTemplate = true
        }
        menu.delegate = self
        statusItem.menu = menu
        manager.captureActiveIdentity()
        populateMenu()
        startAutoSync()
    }

    // MARK: - 동기화
    private func startAutoSync() {
        syncTimer?.invalidate()
        guard autoSync else { watcher?.stop(); return }
        // 감시자와 생명주기 훅이 있으므로 타이머는 보조 수단이면 충분하다.
        // (30초 폴링은 매번 수천 개 파일을 훑어 메모리·I/O 를 크게 잡아먹었다)
        syncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.runSyncInBackground(quiet: true)
        }
        refreshWindowLabels()
        startWatching()
        observeClaudeLifecycle()
        captureInstanceLoginsIfNeeded()
        runSyncInBackground(quiet: true)
    }

    /// 세션 폴더 변화를 감지해 동기화. **우리가 쓴 변화는 무시**해야 한다 —
    /// 그러지 않으면 동기화 → 감시 이벤트 → 동기화 … 로 끝없이 돈다(메모리 폭주의 주원인이었다).
    private func startWatching() {
        // 기본 인스턴스 + 계정별 인스턴스의 계정 루트를 모두 감시해야
        // 새 인스턴스에서 만든 세션도 곧바로 통합된다.
        var roots = Set(manager.discoverFolders().map { $0.url.deletingLastPathComponent() })
        for folder in syncFolders() { roots.insert(folder.deletingLastPathComponent()) }
        watcher = FolderWatcher { [weak self] in
            guard SyncEngine.shared.shouldAcceptWatchEvent() else { return }
            DispatchQueue.main.async { self?.runSyncInBackground(quiet: true) }
        }
        watcher?.watch(Array(roots))
    }

    /// 인스턴스에서 **직접 로그인한 경우** 그 웹세션을 계정 스냅샷으로 저장해 둔다.
    /// (다음 실행부터는 로그인 화면 없이 바로 열린다 — 사용자가 「현재 로그인 저장」을 누르지 않아도 된다)
    /// 살아있는 로그인을 **항상 최신으로** 스냅샷해 둔다(스냅샷이 이미 있어도 갱신).
    /// 낡은 스냅샷을 나중에 씌우면 멀쩡한 로그인이 날아가기 때문에, 신선도 유지가 곧 안전장치다.
    /// 어느 계정으로 로그인돼 있는지는 그 데이터 디렉터리의 config.json 으로 확인한다.
    private func captureInstanceLoginsIfNeeded() {
        var dirs: [URL] = [Paths.appSupportClaude]
        dirs += manager.profiles.map { InstanceManager.dataDir(for: $0.accountUuid) }
        for dir in dirs {
            guard FileManager.default.fileExists(atPath: dir.appending(path: "Cookies").path),
                  WebSession.isLoggedIn(dataDir: dir),
                  let acct = WebSession.loggedInAccount(dataDir: dir) else { continue }
            // 스냅샷이 그 계정 것보다 오래됐을 때만 갱신(불필요한 복사 방지)
            let snapCookies = WebSession.snapshotDir(accountUuid: acct).appending(path: "Cookies")
            let liveCookies = dir.appending(path: "Cookies")
            let snapTime = (try? snapCookies.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let liveTime = (try? liveCookies.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard liveTime > snapTime else { continue }
            if WebSession.snapshot(accountUuid: acct, from: dir) {
                Log.info("로그인 스냅샷 갱신: \(acct.prefix(8))")
            }
        }
    }

    /// Claude 는 **시작할 때만** 세션 폴더를 스캔한다.
    /// → 종료 시점에 동기화해 두면 다음 실행에서 전부 보이고, 실행 직후에도 한 번 맞춘다.
    private func observeClaudeLifecycle() {
        guard !lifecycleObserved else { return }
        lifecycleObserved = true
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == AuthSwitcher.claudeBundleId else { return }
                let launched = name == NSWorkspace.didLaunchApplicationNotification
                Log.info("Claude \(launched ? "실행" : "종료") 감지 → 동기화")
                if launched {
                    self?.refreshWindowLabels()
                } else if let pid = app?.processIdentifier {
                    // 어느 창이 왜 닫혔는지 남긴다(크래시 덤프가 안 남는 종료를 사후 추적하기 위해).
                    let label = self?.windowLabels[pid] ?? "알 수 없는 창"
                    let up = self?.windowStarts[pid].map { Date().timeIntervalSince($0) }
                    CrashWatch.recordTermination(label: label, pid: pid, uptime: up ?? nil)
                    self?.windowLabels[pid] = nil
                    self?.windowStarts[pid] = nil
                }
                // 종료 시점에는 그 창의 폴더에도 채워 넣어야 다음 실행에서 전부 보인다.
                self?.runSyncInBackground(quiet: true, includeRunning: !launched)
                if !launched {
                    self?.adoptNewAccounts()   // 로그인 후 닫힌 임시 창을 계정으로 등록
                    // 종료 직후가 인덱스 유실이 드러나는 시점이다 — 바로 되살린다.
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        guard let folders = self?.syncFolders(), !folders.isEmpty else { return }
                        let orphans = OrphanSessions.find(folders: folders)
                        if !orphans.isEmpty {
                            let n = OrphanSessions.recover(orphans, into: folders)
                            if n > 0 { Log.info("종료 후 유실 세션 복구: \(n)개") }
                        }
                    }
                }
            }
        }
    }

    /// 죽은 인덱스를 동기화 때마다 자동 격리할지. 켜두면 계정 간 세션 수가 항상 같게 유지된다.
    private static let autoCleanKey = "autoCleanDeadIndexes"
    private var autoCleanDead: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoCleanKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoCleanKey) }
    }

    /// pid → 어느 계정 창인지. 프로세스가 사라진 뒤에는 알아낼 수 없어 미리 캐시해 둔다.
    private var windowLabels: [pid_t: String] = [:]
    private var windowStarts: [pid_t: Date] = [:]

    /// 실행 중인 창 목록을 훑어 라벨/시작시각을 갱신.
    private func refreshWindowLabels() {
        for (dirPath, pid) in InstanceManager.runningDataDirs() {
            let acct = WebSession.loggedInAccount(dataDir: URL(fileURLWithPath: dirPath))
            let label = acct.flatMap { a in manager.profiles.first { $0.accountUuid == a }?.displayLabel }
                ?? URL(fileURLWithPath: dirPath).lastPathComponent
            windowLabels[pid] = label
            if windowStarts[pid] == nil {
                windowStarts[pid] = NSRunningApplication(processIdentifier: pid)?.launchDate ?? Date()
            }
        }
    }

    private var busyCountCache = 0
    private var busyCountAt = Date.distantPast

    /// 진행 중 세션 수(30초 캐시). 인스턴스가 하나면 잠금이 없으므로 항상 0.
    private func cachedBusyCount() -> Int {
        if Date().timeIntervalSince(busyCountAt) < 30 { return busyCountCache }
        let folders = syncFolders()
        let value = Set(folders.map(SessionLock.instanceRoot)).count > 1
            ? SessionLock.busyCount(folders: folders) : 0
        busyCountCache = value
        busyCountAt = Date()
        return value
    }

    /// 동기화 대상 = 기본 인스턴스 + 계정별 인스턴스의 모든 세션 폴더.
    private func syncFolders() -> [URL] {
        let accounts = manager.profiles.map(\.accountUuid)
        let all = InstanceManager.allSessionFolders(knownAccounts: accounts, profiles: manager.profiles)
        return all.isEmpty ? manager.discoverFolders().map(\.url) : all
    }

    /// 모든 동기화는 SyncEngine 을 거친다(직렬 실행·최소 간격·자기 쓰기 무시).
    /// 지금 실행 중인 창들이 읽는 세션 폴더 — 여기엔 쓰지 않는다.
    /// Claude 는 시작할 때만 폴더를 읽으므로 넣어도 재시작 전엔 안 보이고,
    /// 사이드바가 저장소 정보를 다시 해석하면서 같은 프로젝트가 잠깐 두 그룹으로 갈라진다.
    private func foldersOfRunningWindows() -> Set<String> {
        var out = Set<String>()
        for (dirPath, _) in InstanceManager.runningDataDirs() {
            for f in InstanceManager.sessionFolders(of: URL(fileURLWithPath: dirPath)) {
                out.insert(f.standardizedFileURL.path)
            }
        }
        return out
    }

    /// - Parameter includeRunning: 그 창을 곧 재시작할 때만 true(그때는 채워 넣어야 한다).
    private func runSyncInBackground(quiet: Bool, includeRunning: Bool = false) {
        SyncEngine.shared.request(folders: { [weak self] in self?.syncFolders() ?? [] },
                                  autoClean: autoCleanDead,
                                  force: !quiet,
                                  skipWriteTo: { [weak self] in
                                      includeRunning ? [] : (self?.foldersOfRunningWindows() ?? [])
                                  }) { [weak self] r in
            guard !r.skipped else { return }
            if r.orphansRecovered > 0 {
                Log.info("고아 세션 복구: \(r.orphansRecovered)개 (비정상 종료로 인덱스 유실)")
            }
            if r.copied > 0 || r.quarantined > 0 {
                Log.info("동기화: 복사 \(r.copied), 격리 \(r.quarantined), 잠금 \(r.lockHeld)")
            }
            DispatchQueue.main.async {
                if !quiet {
                    var msg = "동기화 완료 — \(r.copied)개 통합"
                    if r.quarantined > 0 { msg += ", 빈 세션 \(r.quarantined)개 정리" }
                    if r.lockHeld > 0 || r.lockReleased > 0 { msg += " · 잠금 \(r.lockHeld)/해제 \(r.lockReleased)" }
                    if r.deferredRunning > 0 { msg += " · 실행 중 창 \(r.deferredRunning)건은 재시작 시" }
                    self?.setStatus(msg)
                }
            }
        }
    }

    // MARK: - Dock 아이콘
    /// Dock 표시 여부에 따라 활성화 정책 전환. `.regular` 면 Dock 에 아이콘이 뜬다.
    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        if showDockIcon { installMainMenuIfNeeded() }
    }

    /// Dock 모드(.regular)에서 ⌘Q 등 표준 단축키가 동작하도록 최소 메인 메뉴를 붙인다.
    private func installMainMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Claude 계정 전환기 열기", action: #selector(openFromDock), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    @objc private func openFromDock() { popUpMenuAtMouse() }

    /// Dock 아이콘 클릭(창이 없으므로 reopen 이 온다) → 마우스 위치에 메뉴를 띄운다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        popUpMenuAtMouse()
        return true
    }

    /// Dock 에서 열 때 쓰는 팝업. statusItem 에 물린 메뉴와 충돌하지 않도록 **별도 인스턴스**를 만든다.
    private func popUpMenuAtMouse() {
        let popup = NSMenu()
        build(into: popup)
        NSApp.activate(ignoringOtherApps: true)
        popup.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: - 메뉴 (열 때마다 재구성 → 데스크탑 계정 전환을 즉시 반영)
    func menuNeedsUpdate(_ menu: NSMenu) { populateMenu() }

    private func populateMenu() {
        menu.removeAllItems()
        build(into: menu)
    }

    /// 메뉴 내용 구성(상태 아이콘용·Dock 팝업용 공통).
    private func build(into menu: NSMenu) {
        adoptNewAccounts()          // 로그인 끝난 새 계정이 있으면 먼저 등록
        manager.refreshFromDisk()
        let active = manager.activeAccountUuid()

        let header = NSMenuItem(title: "Claude 계정 전환기", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let running = InstanceManager.runningDataDirs()
        let sorted = manager.profiles.sorted { ($0.email ?? $0.accountUuid) < ($1.email ?? $1.accountUuid) }
        for profile in sorted {
            let count = manager.sessionCount(accountUuid: profile.accountUuid, orgUuid: profile.organizationUuid)
            let isActive = profile.accountUuid == active
            let ready = WebSession.hasSnapshot(accountUuid: profile.accountUuid)
            let dir = InstanceManager.dataDir(for: profile.accountUuid).standardizedFileURL.path
            let isUp = running[dir] != nil || (isActive && running[Paths.appSupportClaude.standardizedFileURL.path] != nil)

            var suffix = ""
            if isUp {
                suffix = "  · 실행 중"
                // 그 창이 시작한 뒤 들어온 세션은 재시작 전까지 목록에 안 뜬다 → 몇 개인지 알려준다.
                let pid = running[dir] ?? running[Paths.appSupportClaude.standardizedFileURL.path]
                if let pid {
                    let instDir = (running[dir] != nil) ? InstanceManager.dataDir(for: profile.accountUuid)
                                                        : Paths.appSupportClaude
                    let stale = InstanceManager.staleCount(pid: pid,
                                                           sessionFolders: InstanceManager.sessionFolders(of: instDir))
                    if stale > 0 { suffix = "  · 실행 중 · 새 세션 \(stale)개(재시작 필요)" }
                }
            }
            else if !ready && !isActive { suffix = "  · 최초 1회 로그인 필요" }

            let item = NSMenuItem(title: "\(profile.displayLabel) — \(count) 세션\(suffix)",
                                  action: #selector(openInstance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.accountUuid
            item.state = isUp ? .on : .off
            menu.addItem(item)
        }
        // 메뉴를 열 때마다 전 인덱스를 다시 읽으면 비싸다 → 짧게 캐시하고,
        // 인스턴스가 2개 이상일 때(=잠금이 의미 있을 때)만 계산한다.
        let busy = cachedBusyCount()
        if busy > 0 {
            let info = NSMenuItem(title: "  진행 중 \(busy)개 — 다른 창에서는 숨김", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }

        addItem(to: menu, "＋ 새 계정 추가…", #selector(addAccount))
        menu.addItem(.separator())
        addItem(to: menu, "지금 세션 동기화", #selector(syncNow), key: "s")
        let auto = addItem(to: menu, "자동 동기화 (30초)", #selector(toggleAutoSync))
        auto.state = autoSync ? .on : .off
        let login = addItem(to: menu, "로그인 시 자동 실행", #selector(toggleLaunchAtLogin))
        login.state = launchAtLoginEnabled ? .on : .off
        let dock = addItem(to: menu, "Dock 아이콘 표시", #selector(toggleDockIcon))
        dock.state = showDockIcon ? .on : .off
        let clean = addItem(to: menu, "빈 세션 자동 정리", #selector(toggleAutoClean))
        clean.state = autoCleanDead ? .on : .off
        let share = addItem(to: menu, "세션 폴더 공유(아카이브까지 반영)", #selector(toggleLinkMode))
        share.state = LinkMode.isEnabled(folders: syncFolders()) ? .on : .off
        menu.addItem(.separator())
        addItem(to: menu, "현재 로그인 저장(전환 대상 등록)", #selector(captureNow))
        addItem(to: menu, "빈 세션 정리(죽은 인덱스 격리)", #selector(cleanDead))
        addItem(to: menu, "가려진 세션 복구(worktree 재활용)", #selector(unshadowNow))
        addItem(to: menu, "백업 폴더 열기", #selector(openBackups))
        addItem(to: menu, "로그 열기", #selector(openLog))
        let quits = CrashWatch.incidentCount()
        if quits > 0 {
            addItem(to: menu, "예기치 않은 종료 기록 \(quits)건 열기", #selector(openQuitLog))
        }
        menu.addItem(.separator())
        addItem(to: menu, "종료", #selector(quit), key: "q")
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    /// 세션 폴더를 **완전히 채운 뒤** 창을 띄운다.
    ///
    /// Claude 는 시작할 때 폴더를 한 번 스캔한다. 동기화가 비동기로 돌면 창이 먼저 떠서
    /// 거의 빈 폴더를 스캔해 버리고, 뒤늦게 도착한 파일은 재시작 전까지 안 보인다
    /// (실측: 창이 뜬 뒤 502개가 기록돼 목록이 텅 빈 것처럼 보였다).
    /// 그래서 여기서는 동기화가 끝날 때까지 기다렸다가 실행한다.
    private func syncThenLaunch(accountUuid: String, quitFirst pid: pid_t?, label: String) {
        setStatus("\(label): 세션 동기화 중…")
        if let pid {
            CrashWatch.markIntentionalQuit()          // 이 종료는 사고가 아니다
            InstanceManager.quitAndWait(pid: pid)     // 먼저 닫아야 안전하게 채운다
        }
        let folders = syncFolders()
        DispatchQueue.global(qos: .userInitiated).async {
            var copied = 0
            var lockedOut = 0
            var linked = 0
            var revived = 0
            autoreleasepool {
                // 창을 띄우기 **직전에** 인덱스가 유실된 세션을 되살린다.
                // Claude 는 세션 인덱스를 곧바로 쓰지 않는 경우가 있어, 방금 만든 세션이
                // 인덱스 없이 남아 있을 수 있다. 주기 복구(30분)를 기다리면 그 사이 재시작한
                // 사용자에겐 세션이 사라진 것으로 보인다 — 그래서 여기서 먼저 확인한다.
                let orphans = OrphanSessions.find(folders: folders)
                if !orphans.isEmpty { revived = OrphanSessions.recover(orphans, into: folders) }
                // 공유 모드가 켜져 있으면 이 창의 폴더도 링크로 바꾼다.
                // 창이 꺼져 있는 지금이 유일하게 안전한 시점이다.
                if LinkMode.isEnabled(folders: folders) {
                    let target = InstanceManager.sessionFolders(of: InstanceManager.dataDir(for: accountUuid))
                    linked = LinkMode.enable(folders: target, runningFolders: []).linked
                }
                // 종료된 창의 폴더이므로 skipWriteTo 없이 전부 채운다.
                copied = SessionSync.syncAll(folders: folders).copied
                // 그런 다음, 다른 창에서 **지금 진행 중**인 세션은 이 창에서 빼둔다.
                // 창이 꺼져 있는 이 순간이 잠금이 실제로 효력을 갖는 유일한 시점이다.
                let target = InstanceManager.sessionFolders(of: InstanceManager.dataDir(for: accountUuid))
                let others = folders.filter { !target.contains($0) }
                lockedOut = SessionLock.filterForLaunch(targetFolders: target, otherFolders: others)
            }
            SessionIndex.flushCaches()
            DispatchQueue.main.async { [weak self] in
                InstanceManager.launch(accountUuid: accountUuid)
                var msg = "\(label) 실행 — 세션 \(copied)개 반영"
                if lockedOut > 0 { msg += ", 다른 창 진행 중 \(lockedOut)개 제외" }
                self?.setStatus(msg)
                self?.populateMenu()
            }
        }
    }

    // MARK: - 액션
    /// 계정 인스턴스를 연다(이미 떠 있으면 앞으로). 여러 계정을 **동시에** 띄울 수 있다.
    @objc private func openInstance(_ sender: NSMenuItem) {
        guard let acct = sender.representedObject as? String,
              let target = manager.profiles.first(where: { $0.accountUuid == acct }) else { return }

        // 이미 실행 중이면: 뒤처진 세션이 있으면 재시작을 제안하고, 아니면 앞으로 가져온다.
        let dirPath = InstanceManager.dataDir(for: acct).standardizedFileURL.path
        if let pid = InstanceManager.runningDataDirs()[dirPath] {
            let instDir = InstanceManager.dataDir(for: acct)
            let stale = InstanceManager.staleCount(pid: pid, sessionFolders: InstanceManager.sessionFolders(of: instDir))
            if stale > 0 {
                let a = NSAlert()
                a.messageText = "\(target.displayLabel) 창을 재시작할까요?"
                a.informativeText = """
                    이 창이 시작한 뒤에 들어온 세션이 \(stale)개 있습니다.
                    Claude 는 시작할 때만 세션 목록을 읽기 때문에, 재시작해야 그 세션들이 보입니다.
                    (진행 중인 작업이 있으면 먼저 저장하세요)
                    """
                a.addButton(withTitle: "재시작")
                a.addButton(withTitle: "그냥 열기")
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn {
                    syncThenLaunch(accountUuid: acct, quitFirst: pid, label: target.displayLabel)
                    return
                }
            }
            InstanceManager.launch(accountUuid: acct)
            return
        }
        let dir = dirPath
        // 현재 로그인 중인 계정이면 기본 인스턴스를 그대로 쓴다
        if acct == manager.activeAccountUuid(),
           InstanceManager.runningDataDirs()[Paths.appSupportClaude.standardizedFileURL.path] != nil {
            setStatus("\(target.displayLabel) 는 기본 창에서 실행 중입니다.")
            return
        }

        if !WebSession.hasSnapshot(accountUuid: acct) {
            let a = NSAlert()
            a.messageText = "\(target.displayLabel) 창을 새로 열까요?"
            a.informativeText = """
                이 계정은 저장된 로그인이 없어 새 창이 로그인 화면으로 시작합니다.
                로그인한 뒤 메뉴의 「현재 로그인 저장」을 누르면, 다음부터는 바로 로그인된 상태로 열립니다.
                """
            a.addButton(withTitle: "열기")
            a.addButton(withTitle: "취소")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }

        syncThenLaunch(accountUuid: acct, quitFirst: nil, label: target.displayLabel)
    }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let acct = sender.representedObject as? String,
              let target = manager.profiles.first(where: { $0.accountUuid == acct }) else { return }
        if manager.activeAccountUuid() == acct { setStatus("이미 \(target.displayLabel)"); return }

        let alert = NSAlert()
        alert.messageText = "\(target.displayLabel) 계정으로 전환할까요?"
        alert.informativeText = "백업·동기화 후 Claude 를 종료했다가 다시 켭니다. (작업 중인 내용은 저장해 주세요)"
        alert.addButton(withTitle: "전환")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let result = AuthSwitcher.performSwitch(to: target, manager: manager)
        if result.needsGuidedLogin {
            let a2 = NSAlert()
            a2.messageText = result.message
            a2.informativeText = """
                이 계정은 아직 저장된 로그인 정보가 없습니다.
                Claude 가 켜지면 \(target.displayLabel) 로 한 번만 로그인한 뒤,
                메뉴에서 「현재 로그인 저장」을 눌러주세요. 다음부터는 원클릭으로 전환됩니다.
                """
            a2.addButton(withTitle: "확인")
            NSApp.activate(ignoringOtherApps: true)
            a2.runModal()
        }
        setStatus(result.message)
        populateMenu()
    }

    /// 아직 이 맥에 없는 계정을 추가한다.
    /// 계정 UUID 는 로그인 전엔 알 수 없으므로 임시 창을 띄우고,
    /// 로그인하면 그 창의 config.json 에서 계정을 읽어 자동 등록한다.
    @objc private func addAccount() {
        let alert = NSAlert()
        alert.messageText = "새 계정을 추가할까요?"
        alert.informativeText = "빈 Claude 창이 하나 열립니다. 그 창에서 추가할 계정으로 로그인하세요.\n"
            + "로그인한 뒤 창을 닫으면 자동으로 계정 목록에 등록되고, 세션도 함께 통합됩니다."
        alert.addButton(withTitle: "창 열기")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if InstanceManager.addNewAccount() != nil {
            setStatus("새 계정 창 열림 — 로그인 후 창을 닫으면 등록됩니다")
        } else {
            setStatus("새 계정 창 실행 실패 — 로그 확인")
        }
    }

    /// 로그인이 끝난 임시 인스턴스를 계정으로 등록(창이 닫힌 뒤에만 수행).
    private func adoptNewAccounts() {
        for (acct, org) in InstanceManager.adoptPendingInstances() {
            manager.addProfileIfMissing(accountUuid: acct, organizationUuid: org)
            setStatus("새 계정 등록됨 — \(acct.prefix(8))")
        }
    }

    @objc private func syncNow() { runSyncInBackground(quiet: false) }
    /// 공유 모드 토글.
    ///
    /// 켜면 모든 계정 폴더가 **하나의 실체**를 가리켜 사본 자체가 사라진다.
    /// 복사 방식에서는 "없는 파일만 채우기"라 아카이브 같은 **상태 변경이 전파되지 않았다**
    /// (실측: 512개 중 209개가 아카이브 상태 불일치). 공유하면 애초에 갈라질 수가 없다.
    @objc private func toggleLinkMode() {
        let folders = syncFolders()
        let on = LinkMode.isEnabled(folders: folders)
        let running = foldersOfRunningWindows()
        let alert = NSAlert()
        alert.messageText = on ? "세션 폴더 공유를 끌까요?" : "세션 폴더를 공유할까요?"
        alert.informativeText = on
            ? "각 계정이 자기 사본을 갖는 예전 방식으로 돌아갑니다. 아카이브 같은 상태 변경은 다시 갈라질 수 있습니다."
            : "모든 계정이 같은 세션 폴더를 보게 됩니다.\n"
              + "한 창에서 아카이브하면 다른 창에도 반영되고(표시는 그 창 재시작 시), 사본이 없어 대량 복사도 사라집니다.\n"
              + "실행 중인 창은 다음 재시작 때 자동 전환됩니다. 원본은 백업에 보관합니다."
        alert.addButton(withTitle: on ? "끄기" : "켜기")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if on {
            let n = LinkMode.disable(folders: folders, runningFolders: running)
            setStatus("공유 모드 해제 — \(n)개 폴더 복원")
        } else {
            let r = LinkMode.enable(folders: folders, runningFolders: running)
            var msg = "공유 모드 — 링크 \(r.linked)개, 상태 정리 \(r.conflictsResolved)개"
            if !r.skippedRunning.isEmpty { msg += " (실행 중 \(r.skippedRunning.count)개는 재시작 때)" }
            setStatus(msg)
        }
        populateMenu()
    }

    @objc private func toggleAutoClean() {
        autoCleanDead.toggle()
        setStatus("빈 세션 자동 정리: \(autoCleanDead ? "켜짐" : "꺼짐")")
    }

    /// Dock 아이콘 표시 토글. 켜면 Dock 아이콘 클릭만으로 메뉴를 열 수 있다
    /// (메뉴바가 꽉 차 상태 아이콘을 누르기 어려울 때 유용).
    @objc private func toggleDockIcon() {
        showDockIcon.toggle()
        applyActivationPolicy()
        setStatus("Dock 아이콘: \(showDockIcon ? "표시" : "숨김")")
    }
    @objc private func toggleAutoSync() { autoSync.toggle(); startAutoSync(); populateMenu() }

    // 로그인 항목(SMAppService). 메뉴바 도구가 항상 켜져 있어야 동기화가 상시 동작한다.
    private var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    @objc private func toggleLaunchAtLogin() {
        do {
            if launchAtLoginEnabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            setStatus("로그인 자동 실행: \(launchAtLoginEnabled ? "켜짐" : "꺼짐")")
        } catch {
            setStatus("로그인 항목 설정 실패 — 시스템 설정 > 일반 > 로그인 항목에서 수동 추가")
            Log.error("launchAtLogin 토글 실패: \(error.localizedDescription)")
        }
        populateMenu()
    }
    /// 현재 로그인(웹세션 + CLI 식별/자격증명)을 현재 계정 프로필로 저장 → 이후 원클릭 전환 가능.
    @objc private func captureNow() {
        manager.captureActiveIdentity()
        manager.captureActiveCredential()
        let alert = NSAlert()
        alert.messageText = "현재 로그인을 저장할까요?"
        alert.informativeText = "웹세션을 저장하려면 Claude 를 잠시 종료했다가 다시 켭니다."
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let ok = AuthSwitcher.captureCurrentWebSession(manager: manager)
        setStatus(ok ? "현재 로그인 저장됨 — 이제 원클릭 전환 가능" : "저장 실패 — 로그 확인")
        populateMenu()
    }

    /// 대화 로그가 사라진 "죽은 인덱스"를 백업으로 격리 → 빈 세션이 목록에서 사라진다.
    @objc private func cleanDead() {
        let folders = manager.discoverFolders().map(\.url)
        let alert = NSAlert()
        alert.messageText = "빈 세션을 정리할까요?"
        alert.informativeText = "대화 로그가 사라진 세션 항목만 백업 폴더로 옮깁니다(삭제 아님).\n정리 후 Claude 를 재시작하면 목록에 반영됩니다."
        alert.addButton(withTitle: "정리")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let n = SessionSync.quarantineDeadIndexes(folders: folders)
        setStatus("빈 세션 \(n)개 격리 완료")
        populateMenu()
    }
    /// worktree 재활용으로 목록에서 가려진 세션을 되살린다(원본 비파괴, 새 항목 추가).
    @objc private func unshadowNow() {
        let folders = manager.discoverFolders().map(\.url)
        guard let first = folders.first else { return }
        let found = ShadowedSessions.find(in: first)
        let alert = NSAlert()
        if found.isEmpty {
            alert.messageText = "가려진 세션이 없습니다."
            alert.informativeText = "worktree 를 여러 세션이 공유해 목록에서 밀려난 세션이 없습니다."
            alert.addButton(withTitle: "확인")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        alert.messageText = "가려진 세션 \(found.count)개를 복구할까요?"
        alert.informativeText = """
            worktree 가 재활용되면 같은 폴더를 쓰던 예전 세션이 목록에서 밀려납니다.
            대화 로그를 본체 저장소 폴더로 복사하고 「(복구)」 항목으로 다시 띄웁니다.
            원본은 지우지 않습니다. 복구 후 Claude 를 재시작해야 보입니다.
            """
        alert.addButton(withTitle: "복구")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let n = ShadowedSessions.unshadow(folders: folders)
        setStatus("가려진 세션 \(n)개 복구 — Claude 재시작 후 표시")
        let done = NSAlert()
        done.messageText = "\(n)개 복구 완료"
        done.informativeText = "Claude 를 재시작하면 「… (복구)」 항목으로 나타납니다."
        done.addButton(withTitle: "확인")
        done.runModal()
        populateMenu()
    }

    @objc private func openBackups() { NSWorkspace.shared.open(Paths.backupsDir) }
    @objc private func openLog() { NSWorkspace.shared.open(Paths.logFile) }
    @objc private func openQuitLog() { NSWorkspace.shared.open(CrashWatch.incidentFile) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func setStatus(_ msg: String) {
        statusItem.button?.toolTip = msg
        Log.info("UI: \(msg)")
    }
}
