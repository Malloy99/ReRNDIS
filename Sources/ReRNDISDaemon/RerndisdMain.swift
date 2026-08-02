// SPDX-License-Identifier: GPL-2.0-or-later
// rerndisd entry point.

import ArgumentParser
import Foundation

let daemonVersion = "rel10"

@main
struct HorndisdCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rerndisd",
        abstract: "Userspace RNDIS tethering daemon.",
        version: daemonVersion,
        subcommands: [RunCommand.self, CleanupCommand.self],
        defaultSubcommand: RunCommand.self
    )
}

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Watch for RNDIS devices and drive them (default)."
    )

    func run() throws {
        runDaemon()
    }
}

struct CleanupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Destroy interfaces left over from a crashed instance."
    )

    func run() throws {
        let cleaned = StateStore.cleanupOrphans()
        print("rerndisd cleanup: removed \(cleaned) orphaned interface pair(s)")
    }
}

private func runDaemon() -> Never {
    DaemonLog.info(.lifecycle, "rerndisd \(daemonVersion) starting")
    if geteuid() != 0 {
        DaemonLog.error(.lifecycle, "not running as root: USB works, but virtual interface creation will fail")
    }
    let orphans = StateStore.cleanupOrphans()
    if orphans > 0 {
        DaemonLog.info(.lifecycle, "cleaned \(orphans) orphaned interface pair(s) from a previous instance")
    }
    let registry = DeviceRegistry()
    let settings = SettingsStore.load()
    UplinkPreference.shared.setPreferred(settings.preferredDevice)
    let bootEnabled = settings.autoStartsOnBoot
    if !bootEnabled {
        let applied = DispatchSemaphore(value: 0)
        Task {
            await registry.setInitialEnabled(false)
            applied.signal()
        }
        applied.wait()
        DaemonLog.info(.lifecycle, "auto start disabled; waiting for the app or rerndisctl enable")
    }
    guard let watcher = USBWatcher(handler: { event in
        Task {
            await registry.handle(event)
        }
    }) else {
        DaemonLog.error(.lifecycle, "failed to create IOKit notification port")
        exit(1)
    }
    let xpcServer = XPCServer(registry: registry)
    Task {
        await registry.setRescanHook { [weak watcher] in
            watcher?.rescan()
        }
    }
    DaemonLog.info(.lifecycle, "watching for RNDIS interfaces (3 shapes) and device-level candidates")

    // Graceful shutdown tears sessions down so feth pairs, routes, and DNS keys
    // never outlive the process (launchd sends SIGTERM on unload).
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let signalSources = [SIGTERM, SIGINT].map { signalNumber in
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            DaemonLog.info(.lifecycle, "signal \(signalNumber): shutting down")
            Task {
                await registry.reapAll(reason: "daemon shutting down")
                exit(0)
            }
        }
        source.resume()
        return source
    }

    withExtendedLifetime((watcher, signalSources, xpcServer)) {
        dispatchMain()
    }
}
