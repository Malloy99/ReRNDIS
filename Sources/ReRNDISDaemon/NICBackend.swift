// SPDX-License-Identifier: GPL-2.0-or-later
// Seam between the RNDIS data plane and the virtual-NIC implementation. feth is
// the primary backend; keeping the surface narrow preserves the documented
// fallback (utun plus a private DHCP client) if a future macOS drops if_fake.
// Frame views are only valid for the duration of each call: implementations
// must consume them synchronously (write into BPF or copy).

import RNDISCore

protocol NICBackend: AnyObject, Sendable {
    /// Creates the virtual interface and starts delivering stack-originated
    /// frames to `onOutboundFrame` (BPF reader thread context; the pointer is
    /// valid only during the callback). Returns the interface name.
    func attach(
        macAddress: [UInt8],
        mtu: Int,
        onOutboundFrame: @escaping @Sendable (UnsafeRawBufferPointer) -> Void
    ) throws -> String

    /// DHCP, router, and DNS bring-up. Slow; runs after the data path is live.
    func completeNetworkSetup() async

    /// Injects every frame of one bulk-in transfer toward the stack. Called
    /// from USB completion context; `transfer` stays valid during the call.
    func inject(transfer: UnsafeRawBufferPointer, frames: [RNDISFraming.FrameRange])

    func detach()
}
