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
        guard autoSync else { return }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.runSyncInBackground(quiet: true)
        }
        runSyncInBackground(quiet: true)
    }

    private func runSyncInBackground(quiet: Bool) {
        let folders = manager.discoverFolders().map(\.url)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = SessionSync.syncAll(folders: folders)
            if r.copied > 0 { Log.info("자동 동기화: \(r.copied)개 복사") }
            DispatchQueue.main.async {
                if !quiet {
                    self?.setStatus("동기화 완료 — \(r.copied)개 통합, 빈 세션 \(r.skippedDead)개 제외")
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
        manager.refreshFromDisk()
        let active = manager.activeAccountUuid()

        let header = NSMenuItem(title: "Claude 계정 전환기", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let sorted = manager.profiles.sorted { ($0.email ?? $0.accountUuid) < ($1.email ?? $1.accountUuid) }
        for profile in sorted {
            let count = manager.sessionCount(accountUuid: profile.accountUuid, orgUuid: profile.organizationUuid)
            let isActive = profile.accountUuid == active
            // 웹세션 스냅샷이 있어야 데스크탑 로그인까지 원클릭 전환된다.
            let ready = WebSession.hasSnapshot(accountUuid: profile.accountUuid)
            let credMark = (isActive || ready) ? "" : "  · 최초 1회 로그인 필요"
            let item = NSMenuItem(title: "\(profile.displayLabel) — \(count) 세션\(credMark)",
                                  action: #selector(switchAccount(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.accountUuid
            item.state = isActive ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        addItem(to: menu, "지금 세션 동기화", #selector(syncNow), key: "s")
        let auto = addItem(to: menu, "자동 동기화 (30초)", #selector(toggleAutoSync))
        auto.state = autoSync ? .on : .off
        let login = addItem(to: menu, "로그인 시 자동 실행", #selector(toggleLaunchAtLogin))
        login.state = launchAtLoginEnabled ? .on : .off
        let dock = addItem(to: menu, "Dock 아이콘 표시", #selector(toggleDockIcon))
        dock.state = showDockIcon ? .on : .off
        menu.addItem(.separator())
        addItem(to: menu, "현재 로그인 저장(전환 대상 등록)", #selector(captureNow))
        addItem(to: menu, "빈 세션 정리(죽은 인덱스 격리)", #selector(cleanDead))
        addItem(to: menu, "백업 폴더 열기", #selector(openBackups))
        addItem(to: menu, "로그 열기", #selector(openLog))
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

    // MARK: - 액션
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

    @objc private func syncNow() { runSyncInBackground(quiet: false) }

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
    @objc private func openBackups() { NSWorkspace.shared.open(Paths.backupsDir) }
    @objc private func openLog() { NSWorkspace.shared.open(Paths.logFile) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func setStatus(_ msg: String) {
        statusItem.button?.toolTip = msg
        Log.info("UI: \(msg)")
    }
}
