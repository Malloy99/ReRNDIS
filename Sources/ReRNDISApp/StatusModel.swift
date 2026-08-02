// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Foundation
import ReRNDISShared
import ServiceManagement
import UserNotifications

@MainActor
final class StatusModel: ObservableObject {
    @Published private(set) var status: DaemonStatus?
    @Published private(set) var reachable = false
    @Published private(set) var rates: [String: (rx: Double, tx: Double)] = [:]
    @Published private(set) var configuration: DaemonConfiguration?
    @Published private(set) var benchmark: BenchmarkResult?
    @Published private(set) var benchmarkRunning = false
    @Published private(set) var benchmarkTarget: String?
    @Published var controlError: String?

    private var connection: NSXPCConnection?
    private var timer: Timer?
    private var lastSample: (time: Date, counters: [String: (rx: UInt64, tx: UInt64)])?
    private var knownDevices: Set<String>?

    private static let activeInterval: TimeInterval = 2
    private static let idleInterval: TimeInterval = 30
    private static let idleNotifyInterval: TimeInterval = 10
    private static let notifyDefaultsKey = "notifyOnConnect"

    var notifiesOnConnect: Bool {
        get { UserDefaults.standard.bool(forKey: Self.notifyDefaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.notifyDefaultsKey)
            if newValue {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
            objectWillChange.send()
            restartTimer(interval: currentIdleInterval)
        }
    }

    private var currentIdleInterval: TimeInterval {
        notifiesOnConnect ? Self.idleNotifyInterval : Self.idleInterval
    }

    init() {
        setEnabled(true)
        refresh()
        fetchConfiguration()
        restartTimer(interval: currentIdleInterval)
    }

    func menuAppeared() {
        refresh()
        fetchConfiguration()
        restartTimer(interval: Self.activeInterval)
    }

    func menuDisappeared() {
        restartTimer(interval: currentIdleInterval)
    }

    private func restartTimer(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func proxy() -> ReRNDISDaemonXPC? {
        if connection == nil {
            connection = ReRNDISXPCClient.makeConnection()
        }
        // The error block runs on an XPC queue: it must not inherit this
        // class's MainActor isolation or the runtime executor check traps.
        let proxyObject = connection?.remoteObjectProxyWithErrorHandler { @Sendable [weak self] _ in
            Task { @MainActor in
                self?.reachable = false
                self?.connection?.invalidate()
                self?.connection = nil
            }
        }
        return proxyObject as? ReRNDISDaemonXPC
    }

    func refresh() {
        proxy()?.fetchStatus { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                guard let data, let status = try? JSONDecoder().decode(DaemonStatus.self, from: data) else {
                    self.reachable = false
                    return
                }
                self.reachable = true
                self.updateRates(with: status)
                self.notifyNewDevices(in: status)
                self.status = status
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        proxy()?.setEnabled(enabled) { [weak self] ok, error in
            Task { @MainActor in
                guard let self else { return }
                self.controlError = ok ? nil : (error ?? "")
                self.refresh()
            }
        }
    }

    func fetchConfiguration() {
        proxy()?.fetchConfiguration { [weak self] data in
            Task { @MainActor in
                guard let self, let data else { return }
                self.configuration = try? JSONDecoder().decode(DaemonConfiguration.self, from: data)
            }
        }
    }

    func applyConfiguration(_ transform: (inout DaemonConfiguration) -> Void) {
        guard var config = configuration else { return }
        transform(&config)
        config = config.clamped()
        configuration = config
        guard let payload = try? JSONEncoder().encode(config) else { return }
        proxy()?.applyConfiguration(payload) { [weak self] ok, error in
            Task { @MainActor in
                guard let self else { return }
                self.controlError = ok ? nil : (error ?? "")
                self.fetchConfiguration()
                self.refresh()
            }
        }
    }

    func setPreferred(_ serial: String?) {
        applyConfiguration { $0.preferredDevice = serial }
    }

    func runBenchmark(deviceID: String?, deviceName: String?) {
        guard !benchmarkRunning else { return }
        benchmarkRunning = true
        benchmark = nil
        benchmarkTarget = deviceName
        proxy()?.runBenchmark(deviceID: deviceID) { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                self.benchmarkRunning = false
                let decoded = data.flatMap { try? JSONDecoder().decode(BenchmarkResult.self, from: $0) }
                self.benchmark = decoded ?? .failure("")
            }
        }
    }

    func setAutoStart(_ enabled: Bool) {
        applyConfiguration { $0.autoStartsOnBoot = enabled }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            controlError = error.localizedDescription
        }
    }

    private func notifyNewDevices(in status: DaemonStatus) {
        let ids = Set(status.devices.map(\.id))
        defer { knownDevices = ids }
        guard let known = knownDevices else { return }
        guard notifiesOnConnect else { return }
        for device in status.devices where !known.contains(device.id) {
            let content = UNMutableNotificationContent()
            content.title = L(.notifyConnectedTitle)
            content.body = device.name
            let request = UNNotificationRequest(
                identifier: "connect-\(device.id)-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func updateRates(with status: DaemonStatus) {
        let now = Date()
        var counters: [String: (rx: UInt64, tx: UInt64)] = [:]
        for device in status.devices {
            counters[device.id] = (device.rxBytes, device.txBytes)
        }
        defer { lastSample = (now, counters) }
        guard let last = lastSample else { return }
        let elapsed = now.timeIntervalSince(last.time)
        guard elapsed > 0.2 else { return }
        var newRates: [String: (rx: Double, tx: Double)] = [:]
        for (name, current) in counters {
            guard let previous = last.counters[name] else { continue }
            let rx = Double(current.rx >= previous.rx ? current.rx - previous.rx : 0) / elapsed
            let tx = Double(current.tx >= previous.tx ? current.tx - previous.tx : 0) / elapsed
            newRates[name] = (rx, tx)
        }
        rates = newRates
    }
}
