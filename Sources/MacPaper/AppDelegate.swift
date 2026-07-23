import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SettingsStore()
    private let powerMonitor = PowerMonitor()
    private lazy var manager = WallpaperManager(store: store, powerMonitor: powerMonitor)
    private lazy var settingsWindow = SettingsWindowController(manager: manager, store: store)
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = manager
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "MacPaper")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "current"
        let presentationKey = "didPresentLibrary-\(version)"
        if !UserDefaults.standard.bool(forKey: presentationKey) {
            UserDefaults.standard.set(true, forKey: presentationKey)
            DispatchQueue.main.async { [weak self] in self?.settingsWindow.present() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.present()
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = powerMonitor.isOnBattery ? L10n.text("menu.battery") : L10n.text("menu.power")
        let statusMenuItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("menu.open_library"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: L10n.text("menu.next"), action: #selector(nextWallpaper), keyEquivalent: "n").target = self
        let pauseTitle = store.configuration.globallyPaused ? L10n.text("menu.resume") : L10n.text("menu.pause")
        menu.addItem(withTitle: pauseTitle, action: #selector(togglePause), keyEquivalent: "p").target = self
        menu.addItem(.separator())
        let login = NSMenuItem(title: L10n.text("menu.launch_at_login"), action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(withTitle: L10n.text("menu.clear_cache"), action: #selector(clearCache), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("menu.quit"), action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func openSettings() { settingsWindow.present() }
    @objc private func nextWallpaper() { manager.nextAll() }
    @objc private func togglePause() { manager.toggleGlobalPause() }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { showError(L10n.text("error.launch_at_login"), error: error) }
    }

    @objc private func clearCache() {
        Task {
            do { try await manager.clearCache() }
            catch { showError(L10n.text("error.clear_cache"), error: error) }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showError(_ message: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
