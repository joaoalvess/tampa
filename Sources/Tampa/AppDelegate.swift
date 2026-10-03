import AppKit
import Carbon
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = DisplayController()
    private let audio = AudioController()
    private let keepAwake = KeepAwakeController()
    private lazy var settings = SettingsModel(display: controller, audio: audio)
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var hotKeys: [HotKey] = []
    private let awakeDot = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
    private let awakeDotOffset = NSPoint(x: 7.5, y: 6.25)
    private var confirmAlert: NSAlert?
    private var confirmDeadline = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        awakeDot.wantsLayer = true
        awakeDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        awakeDot.layer?.cornerRadius = 3
        awakeDot.isHidden = true
        item.button?.addSubview(awakeDot)

        controller.onChange = { [weak self] in self?.refreshVisibleSettings() }
        controller.onExternalConnected = { [weak self] in self?.turnOff(silently: true) }
        controller.onRestoreStuck = { [weak self] in self?.showRestoreStuck() }
        controller.hiDPI.onFailure = { [weak self] in
            self?.refreshVisibleSettings()
            self?.showAlert("Não consegui ativar o texto nítido", "O modo HiDPI foi desligado e o monitor voltou ao normal.")
        }
        keepAwake.onChange = { [weak self] in self?.updateIcon() }
        controller.start()
        audio.start()
        settings.onLoginError = { [weak self] error in
            self?.showAlert("Não consegui alterar a abertura no login", error.localizedDescription)
        }

        hotKeys = [
            HotKey(id: 1, keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
                self?.toggle()
            },
            HotKey(id: 2, keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
                self?.keepAwake.toggle()
            }
        ]
        updateIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        keepAwake.deactivate()
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

        let awakeItem = NSMenuItem(title: "Manter o Mac acordado ☕", action: #selector(toggleKeepAwake), keyEquivalent: "c")
        awakeItem.keyEquivalentModifierMask = [.control, .option, .command]
        awakeItem.target = self
        awakeItem.state = keepAwake.isActive ? .on : .off
        menu.addItem(awakeItem)

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

    @objc private func toggleKeepAwake() {
        keepAwake.toggle()
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
        guard let button = statusItem?.button, let image = statusSymbol() else { return }
        button.image = keepAwake.isActive ? cuttingAwakeDot(from: image) : image
        let dotCenterY = button.isFlipped ? button.bounds.midY - awakeDotOffset.y : button.bounds.midY + awakeDotOffset.y
        awakeDot.frame.origin = NSPoint(x: button.bounds.midX + awakeDotOffset.x - 3, y: dotCenterY - 3)
        awakeDot.isHidden = !keepAwake.isActive
    }

    private func statusSymbol() -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "Tampa")?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    private func cuttingAwakeDot(from symbol: NSImage) -> NSImage {
        let offset = awakeDotOffset
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: rect.midX + offset.x - 4.5, y: rect.midY + offset.y - 4.5, width: 9, height: 9)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Tampa"
        return image
    }
}
