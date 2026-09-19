import Foundation

/// The Mongoose-OS BLE RPC surface the PBL control board speaks.
///
/// The UUIDs are not arbitrary: Mongoose-OS builds them by reinterpreting a
/// 16-character ASCII string as raw UUID bytes, so `_mOS_RPC_data___` becomes
/// 5F6D4F53-5F52-5043-5F64-6174615F5F5F. They are spelled out here rather than
/// derived so they are greppable and fixed.
///
/// See: https://mongoose-os.com/docs/mongoose-os/api/rpc/rpc-gatts.md
public enum MongooseUUID {
    public static let debugService   = "5F6D4F53-5F44-4247-5F53-56435F49445F" // _mOS_DBG_SVC_ID_
    public static let debugLog       = "306D4F53-5F44-4247-5F6C-6F675F5F5F30" // 0mOS_DBG_log___0
    public static let rpcService     = "5F6D4F53-5F52-5043-5F53-56435F49445F" // _mOS_RPC_SVC_ID_
    public static let rpcData        = "5F6D4F53-5F52-5043-5F64-6174615F5F5F" // _mOS_RPC_data___
    public static let rpcTxControl   = "5F6D4F53-5F52-5043-5F74-785F63746C5F" // _mOS_RPC_tx_ctl_
    public static let rpcRxControl   = "5F6D4F53-5F52-5043-5F72-785F63746C5F" // _mOS_RPC_rx_ctl_
}

/// Length framing for the RPC data channel.
///
/// A request writes a 4-byte big-endian length to tx_ctl, then the JSON body to
/// the data characteristic in 20-byte chunks. A response arrives as a notify on
/// rx_ctl carrying the length, after which the data characteristic is *read*
/// repeatedly until that many bytes have accumulated.
public enum RPCFraming {
    /// Chunk size for writes to the data characteristic. 20 bytes is the
    /// conservative floor that survives an unnegotiated BLE MTU (23 - 3 ATT
    /// header bytes); pytboss uses the same figure.
    public static let chunkSize = 20

    public static func encodeLength(_ n: Int) -> [UInt8] {
        var n = n
        var out: [UInt8] = [0, 0, 0, 0]
        for i in 0..<4 {
            out[3 - i] = UInt8(255 & n)
            n >>= 8
        }
        return out
    }

    public static func decodeLength(_ bytes: [UInt8]) -> Int {
        guard bytes.count >= 4 else { return 0 }
        return Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
    }

    public static func chunk(_ payload: [UInt8], size: Int = chunkSize) -> [[UInt8]] {
        guard !payload.isEmpty else { return [] }
        return stride(from: 0, to: payload.count, by: size).map {
            Array(payload[$0..<min($0 + size, payload.count)])
        }
    }
}

/// A frame pushed over the debug-log characteristic.
///
/// The firmware emits lines shaped `<==PB: FE0C…0101 (54)`, where the trailing
/// parenthesised number is the payload's character count. Anything that doesn't
/// split into exactly three whitespace-separated parts, or whose length doesn't
/// match, is dropped — the debug channel carries unrelated chatter too.
public struct DebugFrame: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case status        // FE0B — component + error flags
        case temperatures  // FE0C — every temperature
        case virtualData   // <==PBD: payloads
    }

    public let kind: Kind
    public let payload: String

    public static func parse(_ line: String) -> DebugFrame? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3 else { return nil }
        let (head, payload, tail) = (parts[0], parts[1], parts[2])

        // Trailing part is "(<count>)" — verify it against the payload length.
        guard tail.count >= 2 else { return nil }
        let digits = String(tail.dropFirst().dropLast())
        guard let checksum = Int(digits), checksum == payload.count else { return nil }

        switch head {
        case "<==PB:":
            if payload.hasPrefix("FE0B") { return DebugFrame(kind: .status, payload: payload) }
            if payload.hasPrefix("FE0C") { return DebugFrame(kind: .temperatures, payload: payload) }
            return nil
        case "<==PBD:":
            return DebugFrame(kind: .virtualData, payload: payload)
        default:
            return nil
        }
    }
}
