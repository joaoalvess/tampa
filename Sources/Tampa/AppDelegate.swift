import AppKit
import Carbon
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = DisplayController()
    private let audio = AudioController()
    private lazy var settings = SettingsModel(display: controller, audio: audio)
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var hotKey: HotKey?
    private var confirmAlert: NSAlert?
    private var confirmDeadline = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        controller.onChange = { [weak self] in
            self?.updateIcon()
            self?.refreshVisibleSettings()
        }
        controller.onExternalConnected = { [weak self] in self?.turnOff(silently: true) }
        controller.onRestoreStuck = { [weak self] in self?.showRestoreStuck() }
        controller.hiDPI.onFailure = { [weak self] in
            self?.refreshVisibleSettings()
            self?.showAlert("Não consegui ativar o texto nítido", "O modo HiDPI foi desligado e o monitor voltou ao normal.")
        }
        controller.start()
        audio.start()
        settings.onLoginError = { [weak self] error in
            self?.showAlert("Não consegui alterar a abertura no login", error.localizedDescription)
        }

        hotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.toggle()
        }
        updateIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.restoreBeforeQuit()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let isOff = controller.isBuiltinOff
        let canDisable = controller.canDisable

        let toggleItem = NSMenuItem(title: isOff ? "Ligar tela do Mac" : "Desligar tela do Mac", action: #selector(toggle), keyEquivalent: "t")
        toggleItem.keyEquivalentModifierMask = [.control, .option, .command]
        toggleItem.target = self
        toggleItem.isEnabled = isOff || canDisable
        menu.addItem(toggleItem)

        if !isOff, !canDisable {
            let hint = NSMenuItem(title: "Conecte um monitor para desligar", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Ajustes…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Sair do Tampa", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func toggle() {
        if controller.isBuiltinOff {
            controller.enableBuiltin()
        } else {
            turnOff(silently: false)
        }
    }

    @objc private func openSettings() {
        settings.refresh()
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: settings))
            hosting.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: hosting)
            window.title = "Ajustes do Tampa"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func turnOff(silently: Bool) {
        do {
            try controller.disableBuiltin()
        } catch {
            if silently, case .noExternal = error { return }
            showAlert("Não consegui desligar a tela do Mac", message(for: error))
            return
        }
        if !defaults.bool(forKey: "confirmedOnce") {
            askToKeepOff()
        }
    }

    private func askToKeepOff() {
        let alert = NSAlert()
        alert.messageText = "A tela do Mac foi desligada"
        alert.addButton(withTitle: "Manter desligada")
        alert.addButton(withTitle: "Religar agora")
        confirmAlert = alert
        confirmDeadline = Date().addingTimeInterval(15)
        updateConfirmText()

        let timer = Timer(timeInterval: 1, target: self, selector: #selector(confirmTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .modalPanel)
        NSApp.activate()
        let response = alert.runModal()
        timer.invalidate()
        confirmAlert = nil

        if response == .alertFirstButtonReturn {
            defaults.set(true, forKey: "confirmedOnce")
        } else {
            controller.enableBuiltin()
        }
    }

    @objc private func confirmTick() {
        if confirmDeadline.timeIntervalSinceNow <= 0 {
            NSApp.abortModal()
        } else {
            updateConfirmText()
        }
    }

    private func updateConfirmText() {
        let seconds = max(0, Int(confirmDeadline.timeIntervalSinceNow.rounded()))
        confirmAlert?.informativeText = "Ela volta sozinha em \(seconds)s se você não confirmar.\nPara religar a qualquer momento: ⌃⌥⌘T."
    }

    private func showRestoreStuck() {
        showAlert("Não consegui religar a tela do Mac", "Feche e abra a tampa. Se não resolver, reinicie o Mac.")
    }

    private func showAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }

    private func message(for error: DisplayController.DisableError) -> String {
        switch error {
        case .apiUnavailable:
            return "Esta versão do macOS não oferece a função usada para desligar a tela."
        case .noBuiltin:
            return "Não encontrei a tela do Mac."
        case .noExternal:
            return "Conecte um monitor antes de desligar a tela do Mac."
        case .system(let error):
            return "O macOS recusou o pedido (CGError \(error.rawValue))."
        }
    }

    private func refreshVisibleSettings() {
        guard settingsWindow?.isVisible == true else { return }
        settings.refresh()
    }

    private func updateIcon() {
        let symbol = controller.isBuiltinOff ? "laptopcomputer.slash" : "laptopcomputer"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tampa")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }
}
