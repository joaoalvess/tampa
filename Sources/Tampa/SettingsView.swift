import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class SettingsModel {
    private(set) var autoDisable = false
    private(set) var hiDPI = false
    private(set) var hiDPISize = HiDPIController.Size.standard
    private(set) var usesHighestRefreshRate = true
    private(set) var avoidsDisplayAudio = true
    private(set) var opensAtLogin = false
    private(set) var loginNeedsApproval = false

    @ObservationIgnored var onLoginError: ((Error) -> Void)?
    @ObservationIgnored private let display: DisplayController
    @ObservationIgnored private let audio: AudioController

    init(display: DisplayController, audio: AudioController) {
        self.display = display
        self.audio = audio
        refresh()
    }

    func refresh() {
        autoDisable = display.autoDisable
        hiDPI = display.hiDPI.isEnabled
        hiDPISize = display.hiDPI.size
        usesHighestRefreshRate = display.usesHighestRefreshRate
        avoidsDisplayAudio = audio.avoidsDisplayOutput
        let status = SMAppService.mainApp.status
        opensAtLogin = status == .enabled
        loginNeedsApproval = status == .requiresApproval
    }

    func title(for size: HiDPIController.Size) -> String {
        let point = display.hiDPI.pointSize(for: size)
        return point.width > 0 ? "\(size.title) (\(point.width) × \(point.height))" : size.title
    }

    func setAutoDisable(_ enabled: Bool) {
        display.autoDisable = enabled
        refresh()
    }

    func setHiDPI(_ enabled: Bool) {
        display.setHiDPI(enabled)
        refresh()
    }

    func setHiDPISize(_ size: HiDPIController.Size) {
        display.setHiDPISize(size)
        refresh()
    }

    func setUsesHighestRefreshRate(_ enabled: Bool) {
        display.usesHighestRefreshRate = enabled
        refresh()
    }

    func setAvoidsDisplayAudio(_ enabled: Bool) {
        audio.avoidsDisplayOutput = enabled
        refresh()
    }

    func setOpensAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            onLoginError?(error)
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        refresh()
    }
}

struct SettingsView: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section("Tela do Mac") {
                Toggle("Desligar automaticamente ao conectar um monitor", isOn: Binding(get: { model.autoDisable }, set: model.setAutoDisable))
                LabeledContent("Desligar ou ligar a qualquer momento", value: "⌃⌥⌘T")
            }

            Section("Monitor externo") {
                Toggle("Texto nítido (HiDPI)", isOn: Binding(get: { model.hiDPI }, set: model.setHiDPI))
                Picker("Tamanho", selection: Binding(get: { model.hiDPISize }, set: model.setHiDPISize)) {
                    ForEach(HiDPIController.Size.allCases, id: \.self) { size in
                        Text(model.title(for: size)).tag(size)
                    }
                }
                .disabled(!model.hiDPI)
                Toggle("Usar sempre a maior taxa de atualização", isOn: Binding(get: { model.usesHighestRefreshRate }, set: model.setUsesHighestRefreshRate))
            }

            Section("Som") {
                Toggle("Não usar o monitor como saída de som", isOn: Binding(get: { model.avoidsDisplayAudio }, set: model.setAvoidsDisplayAudio))
            }

            Section("Geral") {
                Toggle("Abrir no login", isOn: Binding(get: { model.opensAtLogin }, set: model.setOpensAtLogin))
                if model.loginNeedsApproval {
                    LabeledContent("Falta aprovar o Tampa nos Itens de Início") {
                        Button("Abrir Ajustes do Sistema") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
    }
}
