// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import ReRNDISShared

struct MenuView: View {
    @ObservedObject var model: StatusModel
    @ObservedObject var installer: InstallerService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ReRNDIS")
                    .font(.headline)
                Spacer()
                if model.reachable, let status = model.status {
                    Toggle(L(.toggleEnabled), isOn: Binding(
                        get: { status.enabled },
                        set: { model.setEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }

            if !model.reachable {
                Text(L(.daemonUnreachable))
                    .foregroundStyle(.secondary)
                if installer.canInstall {
                    HStack {
                        Button(L(.installerInstall)) {
                            installer.install()
                        }
                        if installer.state == .working {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .disabled(installer.state == .working)
                } else {
                    Text(L(.daemonUnreachableHint))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let failure = installer.failure {
                    Text(L(.installerFailedFormat, failure))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else if let status = model.status {
                if let controlError = model.controlError {
                    Text(controlErrorText(controlError))
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Divider()

                Text(L(.devicesSectionTitle))
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)

                if status.devices.isEmpty {
                    Text(L(.devicesEmpty))
                        .foregroundStyle(.secondary)
                    Text(L(.devicesEmptyHint))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(status.devices) { device in
                        DeviceRow(model: model, device: device)
                    }
                }
            } else {
                Text(L(.statusLoading))
                    .foregroundStyle(.secondary)
            }

            if model.reachable, model.status?.enabled == true {
                Divider()
                settingsSection
                if model.benchmarkRunning || model.benchmark != nil {
                    Divider()
                    benchmarkSection
                }
            }

            Divider()

            HStack {
                if model.reachable, installer.canInstall, case .installed = installer.state {
                    Button(L(.installerUninstall)) {
                        installer.uninstall()
                    }
                    .controlSize(.small)
                    .disabled(installer.state == .working)
                }
                Spacer()
                Button(L(.menuQuit)) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear {
            model.menuAppeared()
            installer.refresh()
        }
        .onDisappear {
            model.menuDisappeared()
        }
    }

    @ViewBuilder
    private var settingsSection: some View {
        if let config = model.configuration {
            HStack {
                Text(L(.settingsTXMode))
                    .font(.callout)
                Spacer()
                Picker(L(.settingsTXMode), selection: Binding(
                    get: { config.txMode },
                    set: { mode in model.applyConfiguration { $0.txMode = mode } }
                )) {
                    Text(L(.txModeOrdered)).tag(DaemonConfiguration.TXMode.ordered)
                    Text(L(.txModeBalanced)).tag(DaemonConfiguration.TXMode.balanced)
                    Text(L(.txModePipelined)).tag(DaemonConfiguration.TXMode.pipelined)
                    Text(L(.txModeThroughput)).tag(DaemonConfiguration.TXMode.throughput)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            HStack {
                Text(L(.settingsRXReaders))
                    .font(.callout)
                Spacer()
                HStack(spacing: 6) {
                    Text(L(.settingsRXReadersValue, config.rxReaders))
                        .font(.callout.monospacedDigit())
                        .frame(minWidth: 30)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                                )
                        )
                    Stepper(L(.settingsRXReaders), value: Binding(
                        get: { config.rxReaders },
                        set: { value in model.applyConfiguration { $0.rxReaders = value } }
                    ), in: DaemonConfiguration.rxReaderRange)
                    .labelsHidden()
                }
            }

            Text(L(.settingsRestartNote))
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack {
                Text(L(.settingsAutoStart))
                    .font(.callout)
                Spacer()
                Toggle(L(.settingsAutoStart), isOn: Binding(
                    get: { config.autoStartsOnBoot },
                    set: { model.setAutoStart($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            HStack {
                Text(L(.settingsNotifyConnect))
                    .font(.callout)
                Spacer()
                Toggle(L(.settingsNotifyConnect), isOn: Binding(
                    get: { model.notifiesOnConnect },
                    set: { model.notifiesOnConnect = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var benchmarkSection: some View {
        if model.benchmarkRunning {
            HStack {
                ProgressView()
                    .controlSize(.small)
                if let target = model.benchmarkTarget {
                    Text(target)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else if let result = model.benchmark {
            if let target = model.benchmarkTarget {
                Text(target)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            benchmarkRows(result)
        }
    }

    @ViewBuilder
    private func benchmarkRows(_ result: BenchmarkResult) -> some View {
        if let reason = result.failureReason {
            Text(L(.benchFailedFormat, benchFailureText(reason)))
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            if let rate = result.txBytesPerSecond {
                Text(L(.benchTXFormat, byteRate(rate)))
                    .font(.caption.monospacedDigit())
            }
            if let p50 = result.rttMillisP50, let p95 = result.rttMillisP95 {
                Text(L(.benchRTTFormat, p50, p95))
                    .font(.caption.monospacedDigit())
            }
        }
    }

    private func benchFailureText(_ raw: String) -> String {
        switch raw {
        case "no active device": L(.benchNoDevice)
        case "admin privileges required": L(.controlAdminRequired)
        case "": L(.controlFailed)
        default: raw
        }
    }

    private func controlErrorText(_ raw: String) -> String {
        switch raw {
        case "admin privileges required":
            return L(.controlAdminRequired)
        case "":
            return L(.controlFailed)
        default:
            return raw
        }
    }

}

private func phaseText(_ device: DaemonStatus.Device) -> String {
    switch device.phase {
    case "up":
        let name = device.interfaceName ?? L(.interfacePlaceholder)
        return device.linkUp ? L(.phaseUpConnected, name) : L(.phaseUpWaitingLink, name)
    case "initializing":
        return L(.phaseInitializing)
    case "failed":
        return L(.phaseFailed)
    default:
        return device.phase
    }
}

private func byteRate(_ value: Double) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .binary
    return formatter.string(fromByteCount: Int64(value)) + "/s"
}

private struct DeviceRow: View {
    @ObservedObject var model: StatusModel
    let device: DaemonStatus.Device
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                guard let serial = device.serial else { return }
                let alreadyPreferred = model.configuration?.preferredDevice == serial
                model.setPreferred(alreadyPreferred ? nil : serial)
            } label: {
                HStack(spacing: 8) {
                    icon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(phaseText(device))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let rate = model.rates[device.id] {
                            Text(L(.ratesFormat, byteRate(rate.rx), byteRate(rate.tx)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(device.serial == nil)
            .help(L(.devicePreferredHelp))

            Button {
                model.runBenchmark(deviceID: device.id, deviceName: device.name)
            } label: {
                Image(systemName: "speedometer")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.benchmarkRunning || device.phase != "up")
            .help(L(.benchNote))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
        )
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
    }

    private var icon: some View {
        let isPreferred = device.serial != nil && model.configuration?.preferredDevice == device.serial
        return ZStack {
            Circle()
                .fill(isPreferred ? Color.accentColor : Color.gray.opacity(0.18))
                .frame(width: 26, height: 26)
            Image(systemName: "iphone")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isPreferred ? Color.white : Color.secondary)
        }
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(device.phase == "up" && device.linkUp ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
        }
    }
}
