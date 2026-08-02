// SPDX-License-Identifier: GPL-2.0-or-later
// Keys are an enum so a typo is a compile error; the test suite asserts
// every language ships exactly this key set.

import Foundation

enum LocalizedKey: String, CaseIterable {
    case daemonUnreachable = "daemon.unreachable"
    case daemonUnreachableHint = "daemon.unreachable.hint"
    case toggleEnabled = "toggle.enabled"
    case controlAdminRequired = "control.adminRequired"
    case controlFailed = "control.failed"
    case devicesSectionTitle = "devices.section.title"
    case devicesEmpty = "devices.empty"
    case devicesEmptyHint = "devices.empty.hint"
    case statusLoading = "status.loading"
    case menuQuit = "menu.quit"
    case phaseUpConnected = "phase.up.connected"
    case phaseUpWaitingLink = "phase.up.waitingLink"
    case phaseInitializing = "phase.initializing"
    case phaseFailed = "phase.failed"
    case interfacePlaceholder = "interface.placeholder"
    case ratesFormat = "rates.format"
    case settingsTXMode = "settings.txMode"
    case txModeOrdered = "txmode.ordered"
    case txModeBalanced = "txmode.balanced"
    case txModePipelined = "txmode.pipelined"
    case txModeThroughput = "txmode.throughput"
    case settingsRXReaders = "settings.rxReaders"
    case settingsRXReadersValue = "settings.rxReaders.value"
    case settingsRestartNote = "settings.restartNote"
    case benchTXFormat = "bench.tx.format"
    case benchRTTFormat = "bench.rtt.format"
    case benchFailedFormat = "bench.failed.format"
    case benchNoDevice = "bench.noDevice"
    case benchNote = "bench.note"
    case settingsAutoStart = "settings.autoStart"
    case settingsNotifyConnect = "settings.notifyConnect"
    case notifyConnectedTitle = "notify.connected.title"
    case devicePreferredHelp = "device.preferred.help"
    case installerInstall = "installer.install"
    case installerUninstall = "installer.uninstall"
    case installerFailedFormat = "installer.failed.format"
}

// Bundle.module cannot ship inside an .app: its only fallback is an absolute
// path on the build machine, so it traps everywhere else. Resolve the SwiftPM
// resource bundle against both real layouts and degrade to raw keys instead.
private let localizationBundle: Bundle = {
    let name = "ReRNDIS_ReRNDISApp.bundle"
    for base in [Bundle.main.resourceURL, Bundle.main.bundleURL] {
        if let bundle = base.flatMap({ Bundle(url: $0.appendingPathComponent(name)) }) {
            return bundle
        }
    }
    return .main
}()

func L(_ key: LocalizedKey) -> String {
    String(localized: String.LocalizationValue(key.rawValue), bundle: localizationBundle)
}

func L(_ key: LocalizedKey, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}
