// SPDX-License-Identifier: GPL-2.0-or-later
// Transport-agnostic RNDIS control-plane state machine. The USB daemon supplies
// an EP0 transport; tests supply a scripted mock. Response waiting follows the
// interrupt-then-poll ladder: honor RESPONSE_AVAILABLE when the device sends it,
// fall back to the kext's 10 x 20ms poll loop when it does not.

import Foundation

public protocol RNDISEncapsulatedTransport: Sendable {
    func sendEncapsulated(_ message: Data) async throws
    /// One GET_ENCAPSULATED_RESPONSE. nil or empty means nothing available yet.
    func readEncapsulated() async throws -> [UInt8]?
    /// Returns when the device signals RESPONSE_AVAILABLE or the timeout passes.
    /// Transports without a usable interrupt endpoint return immediately.
    func waitResponseAvailable(timeoutMilliseconds: Int) async
}

public enum RNDISSessionError: Error, Equatable {
    case responseTimeout
    case deviceReportedFailure(status: UInt32)
    case malformedResponse(String)
}

public actor RNDISControlSession {
    public struct DeviceCapabilities: Sendable, Equatable {
        public let maxTransferSize: Int
        public let maxPacketsPerTransfer: Int
        public let packetAlignmentFactor: Int

        public init(maxTransferSize: Int, maxPacketsPerTransfer: Int, packetAlignmentFactor: Int) {
            self.maxTransferSize = maxTransferSize
            self.maxPacketsPerTransfer = maxPacketsPerTransfer
            self.packetAlignmentFactor = packetAlignmentFactor
        }
    }

    public enum LinkEvent: Sendable, Equatable {
        case connect
        case disconnect
    }

    private let transport: any RNDISEncapsulatedTransport
    private let log: @Sendable (String) -> Void
    private let onLinkEvent: @Sendable (LinkEvent) -> Void
    private var requestCounter: UInt32 = 0

    public init(
        transport: any RNDISEncapsulatedTransport,
        log: @escaping @Sendable (String) -> Void = { _ in },
        onLinkEvent: @escaping @Sendable (LinkEvent) -> Void = { _ in }
    ) {
        self.transport = transport
        self.log = log
        self.onLinkEvent = onLinkEvent
    }

    private func nextRequestID() -> UInt32 {
        requestCounter &+= 1
        if requestCounter == 0 { requestCounter = 1 }
        return requestCounter
    }

    // MARK: - Commands

    public func initialize(
        maxTransferSize: UInt32 = RNDIS.HOST_MAX_TRANSFER_SIZE
    ) async throws -> DeviceCapabilities {
        let requestID = nextRequestID()
        let reply = try await roundTrip(
            RNDISControl.initializeMessage(requestID: requestID, maxTransferSize: maxTransferSize)
        ) { message in
            if case .initializeComplete(let rid, _, _, _, _) = message { return rid == requestID }
            return false
        }
        guard case let .initializeComplete(_, status, maxPackets, deviceMaxTransfer, alignment) = reply else {
            throw RNDISSessionError.malformedResponse("expected INITIALIZE_CMPLT")
        }
        guard status == RNDIS.STATUS_SUCCESS else {
            throw RNDISSessionError.deviceReportedFailure(status: status)
        }
        return DeviceCapabilities(
            maxTransferSize: Int(deviceMaxTransfer),
            maxPacketsPerTransfer: max(1, Int(maxPackets)),
            packetAlignmentFactor: Int(alignment)
        )
    }

    public func query(oid: UInt32, payload: [UInt8] = []) async throws -> [UInt8] {
        let requestID = nextRequestID()
        let reply = try await roundTrip(
            RNDISControl.queryMessage(requestID: requestID, oid: oid, payload: payload)
        ) { message in
            if case .queryComplete(let rid, _, _) = message { return rid == requestID }
            return false
        }
        guard case let .queryComplete(_, status, info) = reply else {
            throw RNDISSessionError.malformedResponse("expected QUERY_CMPLT")
        }
        guard status == RNDIS.STATUS_SUCCESS else {
            throw RNDISSessionError.deviceReportedFailure(status: status)
        }
        return info
    }

    public func queryPermanentMACAddress() async throws -> [UInt8] {
        let info = try await query(oid: RNDIS.OID_802_3_PERMANENT_ADDRESS)
        guard info.count >= 6 else {
            throw RNDISSessionError.malformedResponse("MAC query returned \(info.count) bytes")
        }
        return Array(info.prefix(6))
    }

    /// Best effort initial link state; many gadgets do not implement the OID.
    public func queryMediaConnected() async -> Bool? {
        guard let info = try? await query(oid: RNDIS.OID_GEN_MEDIA_CONNECT_STATUS), info.count >= 4 else {
            return nil
        }
        let value = UInt32(info[0]) | UInt32(info[1]) << 8 | UInt32(info[2]) << 16 | UInt32(info[3]) << 24
        return value == 0
    }

    public func setPacketFilter(_ filter: UInt32) async throws {
        let requestID = nextRequestID()
        let reply = try await roundTrip(
            RNDISControl.setPacketFilterMessage(requestID: requestID, filter: filter)
        ) { message in
            if case .setComplete(let rid, _) = message { return rid == requestID }
            return false
        }
        guard case let .setComplete(_, status) = reply else {
            throw RNDISSessionError.malformedResponse("expected SET_CMPLT")
        }
        guard status == RNDIS.STATUS_SUCCESS else {
            throw RNDISSessionError.deviceReportedFailure(status: status)
        }
    }

    /// Fire and forget on the way out; the device may already be gone.
    public func halt() async {
        try? await transport.sendEncapsulated(RNDISControl.haltMessage(requestID: nextRequestID()))
    }

    /// RESET recovery: RESET_C carries no request id, so match by type alone.
    public func reset() async throws {
        let reply = try await roundTrip(RNDISControl.resetMessage()) { message in
            if case .resetComplete = message { return true }
            return false
        }
        guard case let .resetComplete(status, _) = reply else {
            throw RNDISSessionError.malformedResponse("expected RESET_CMPLT")
        }
        guard status == RNDIS.STATUS_SUCCESS else {
            throw RNDISSessionError.deviceReportedFailure(status: status)
        }
    }

    /// Drains one pending message outside a command round trip. Driven by
    /// RESPONSE_AVAILABLE interrupts while the link is idle, so unsolicited
    /// INDICATE_STATUS and KEEPALIVE get handled promptly.
    public func pumpUnsolicited() async {
        guard let bytes = try? await transport.readEncapsulated(), !bytes.isEmpty else { return }
        guard let message = try? RNDISControlMessage.parse(bytes) else {
            log("dropping malformed unsolicited control message (\(bytes.count) bytes)")
            return
        }
        await handleUnsolicited(message)
    }

    // MARK: - Round trip

    private func roundTrip(
        _ message: Data,
        matches: (RNDISControlMessage) -> Bool
    ) async throws -> RNDISControlMessage {
        try await transport.sendEncapsulated(message)
        await transport.waitResponseAvailable(timeoutMilliseconds: 100)
        for _ in 0..<10 {
            let bytes = try await transport.readEncapsulated()
            if let bytes, !bytes.isEmpty {
                let parsed: RNDISControlMessage
                do {
                    parsed = try RNDISControlMessage.parse(bytes)
                } catch {
                    log("dropping malformed control response: \(error)")
                    continue
                }
                if matches(parsed) { return parsed }
                await handleUnsolicited(parsed)
                continue
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        throw RNDISSessionError.responseTimeout
    }

    private func handleUnsolicited(_ message: RNDISControlMessage) async {
        switch message {
        case .keepalive(let requestID):
            try? await transport.sendEncapsulated(RNDISControl.keepaliveCompleteMessage(requestID: requestID))
        case .indicateStatus(let status) where status == RNDIS.STATUS_MEDIA_CONNECT:
            onLinkEvent(.connect)
        case .indicateStatus(let status) where status == RNDIS.STATUS_MEDIA_DISCONNECT:
            onLinkEvent(.disconnect)
        case .indicateStatus(let status):
            log(String(format: "unhandled INDICATE_STATUS 0x%08x", status))
        default:
            log("ignoring unexpected control message: \(message)")
        }
    }
}
