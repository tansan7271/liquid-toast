import AppKit
import ApplicationServices
import ServiceManagement

/// 시스템 언어가 한국어면 한국어, 아니면 영어.
func L(_ ko: String, _ en: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("ko") == true ? ko : en
}

enum Prefs {
    private static let defaults = UserDefaults.standard

    /// 토스트를 띄울지. 처음엔 켜짐.
    static var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
}

/// 메뉴바에 물방울 아이콘 하나를 두고, 음량·밝기·재생 같은 기능 키를 누르거나 Dock 가리기가 바뀌면
/// 화면 가운데에 유리 토스트를 띄워 그 아이콘으로 날려 보낸다. 사용자가 정한 단축키에도 고른 아이콘을 띄운다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let toast = GlassToast()
    private let keys = KeyWatcher()
    private let dock = DockWatcher()
    private let shortcuts = ShortcutStore()
    private lazy var shortcutWatcher = ShortcutWatcher(store: shortcuts)
    private lazy var settingsUI = SettingsUI(store: shortcuts)
    private let settingsWindow = SettingsWindowController()
    /// 손쉬운 사용 권한이 허용되기를 기다리는 동안만 도는 확인 타이머.
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        statusItem.menu = menu
        keys.onAction = { [weak self] action, _ in
            self?.keyPressed(action)
        }
        dock.onChange = { [weak self] hidden in
            self?.show(hidden ? "dock.arrow.down.rectangle" : "dock.arrow.up.rectangle", group: "dock")
        }
        shortcutWatcher.onMatch = { [weak self] rule in
            self?.show(rule.symbol, group: "custom-\(rule.id)")
        }
        shortcutWatcher.isPaused = { [weak self] in self?.settingsUI.recordingID != nil }
        shortcuts.onChange = { [weak self] in self?.sync(prompt: false) }
        sync(prompt: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        keys.stop()
        dock.stop()
        shortcutWatcher.stop()
    }

    // MARK: 켜고 끄기

    /// 설정대로 감시를 켜고 끈다. 기능 키 감시는 손쉬운 사용 권한이 있어야 하고, Dock 감시는 권한이 필요 없다.
    /// 권한이 없으면 (prompt가 참일 때) 시스템 안내를 띄우고, 허용될 때까지 가끔 확인하다가 허용되면 바로 켠다.
    private func sync(prompt: Bool) {
        updateIcon()
        trustTimer?.invalidate()
        trustTimer = nil
        guard Prefs.enabled else {
            keys.stop()
            dock.stop()
            shortcutWatcher.stop()
            return
        }
        dock.start()
        guard AXIsProcessTrusted() else {
            keys.stop()
            shortcutWatcher.stop()
            if prompt {
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            let timer = Timer(timeInterval: 2, target: self, selector: #selector(checkTrust), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            trustTimer = timer
            return
        }
        keys.start()
        // 일반 키 입력을 받는 감시라서, 정해 둔 단축키가 있을 때만 켠다.
        if shortcuts.hasActiveRules {
            shortcutWatcher.start()
        } else {
            shortcutWatcher.stop()
        }
    }

    @objc private func checkTrust() {
        if AXIsProcessTrusted() {
            sync(prompt: false)
        }
    }

    private func updateIcon() {
        let image = NSImage(systemSymbolName: Prefs.enabled ? "drop.fill" : "drop",
                            accessibilityDescription: "Liquid Toast")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = Prefs.enabled ? "Liquid Toast" : L("Liquid Toast (꺼짐)", "Liquid Toast (off)")
    }

    // MARK: 토스트

    private func show(_ symbol: String, group: String) {
        toast.show(.symbol(symbol), group: group, flyingTo: statusItem.button)
    }

    /// group이 같은 것끼리는 날아가던 방울을 다시 불러들이고, 다르면 새 방울을 띄운다.
    private func keyPressed(_ action: KeyWatcher.Action) {
        switch action {
        case .volumeUp: show("speaker.plus.fill", group: "volume")
        case .volumeDown: show("speaker.minus.fill", group: "volume")
        case .mute:
            // 켜졌는지 꺼졌는지는 시스템이 처리한 뒤에야 알 수 있어서 아주 잠깐 기다렸다가 읽는다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated {
                    let muted = AudioState.read()?.muted ?? true
                    self.show(muted ? "speaker.slash.fill" : "speaker.wave.2.fill", group: "volume")
                }
            }
        case .brightnessUp: show("sun.max.fill", group: "brightness")
        case .brightnessDown: show("sun.min.fill", group: "brightness")
        case .keyLightUp: show("light.max", group: "keylight")
        case .keyLightDown: show("light.min", group: "keylight")
        case .playPause: show("playpause.fill", group: "media")
        case .next: show("forward.fill", group: "media")
        case .previous: show("backward.fill", group: "media")
        }
    }

    // MARK: 메뉴

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let enabled = item(L("토스트 띄우기", "Show toasts"), #selector(toggleEnabled))
        enabled.state = Prefs.enabled ? .on : .off
        menu.addItem(enabled)
        menu.addItem(item(L("미리 보기", "Preview"), #selector(preview)))
        menu.addItem(item(L("단축키 토스트 설정…", "Shortcut Toasts…"), #selector(openSettings), key: ","))

        if Prefs.enabled, !AXIsProcessTrusted() {
            menu.addItem(.separator())
            menu.addItem(item(L("⚠️ 손쉬운 사용 권한 허용하기…", "⚠️ Allow Accessibility access…"),
                              #selector(openAccessibilitySettings)))
            let note = NSMenuItem(title: L("허용 전에는 Dock 가리기만 알려요", "Until then, only Dock changes are shown"),
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            note.indentationLevel = 1
            menu.addItem(note)
        }

        menu.addItem(.separator())
        let login = item(L("로그인할 때 실행", "Open at login"), #selector(toggleLaunchAtLogin))
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item(L("Liquid Toast 종료", "Quit Liquid Toast"), #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleEnabled() {
        Prefs.enabled.toggle()
        sync(prompt: Prefs.enabled)
    }

    @objc private func preview() {
        // 메뉴가 닫힌 뒤에 띄워야 메뉴에 가리지 않는다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated {
                self.show("drop.fill", group: "preview")
            }
        }
    }

    @objc private func openSettings() {
        settingsWindow.show(ui: settingsUI) { [weak self] symbol in
            self?.show(symbol, group: "preview")
        }
    }

    @objc private func openAccessibilitySettings() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("로그인 항목을 바꾸지 못했어요", "Couldn't change the login item")
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
