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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Paths.ensureAppDir()
        Log.info("앱 시작")

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
            let n = SessionSync.syncAll(folders: folders)
            if n > 0 { Log.info("자동 동기화: \(n)개 복사") }
            DispatchQueue.main.async {
                if !quiet { self?.setStatus("세션 동기화 완료 — \(n)개 통합") }
            }
        }
    }

    // MARK: - 메뉴 (열 때마다 재구성 → 데스크탑 계정 전환을 즉시 반영)
    func menuNeedsUpdate(_ menu: NSMenu) { populateMenu() }

    private func populateMenu() {
        manager.refreshFromDisk()
        menu.removeAllItems()
        let active = manager.activeAccountUuid()

        let header = NSMenuItem(title: "Claude 계정 전환기", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let sorted = manager.profiles.sorted { ($0.email ?? $0.accountUuid) < ($1.email ?? $1.accountUuid) }
        for profile in sorted {
            let count = manager.sessionCount(accountUuid: profile.accountUuid, orgUuid: profile.organizationUuid)
            let isActive = profile.accountUuid == active
            let hasCred = Keychain.hasProfileCredential(accountUuid: profile.accountUuid)
            let credMark = hasCred ? "" : "  · 로그인 필요"
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
        menu.addItem(.separator())
        addItem(to: menu, "현재 계정 포착(전환 대상 등록)", #selector(captureNow))
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
        alert.informativeText = "먼저 모든 세션을 백업·동기화한 뒤 Claude 를 재기동합니다."
        alert.addButton(withTitle: "전환")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let result = AuthSwitcher.performSwitch(to: target, manager: manager)
        if result.needsGuidedLogin {
            let a2 = NSAlert()
            a2.messageText = result.message
            a2.informativeText = "Claude 가 재기동되면 \(target.displayLabel) 로 로그인하세요. 이후에는 이 계정도 한 번의 클릭으로 전환됩니다."
            a2.addButton(withTitle: "확인")
            a2.runModal()
        }
        setStatus(result.message)
        populateMenu()
    }

    @objc private func syncNow() { runSyncInBackground(quiet: false) }
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
    @objc private func captureNow() {
        let ok = manager.captureActiveProfile()
        setStatus(ok ? "현재 계정 포착됨" : "포착 실패 — 로그 확인")
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
