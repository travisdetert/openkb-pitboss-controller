import Foundation

/// Port of `pytboss/codec.py` — the obfuscation the PB firmware applies to the
/// optional grill password. Not cryptography and not treated as such: it exists
/// only because the firmware expects it. The password never leaves the device
/// pairing, and an empty password (the default) skips this path entirely.
public enum Codec {
    public static let key: [UInt8] = [0x8F, 0x80, 0x19, 0xCF, 0x77, 0x6C, 0xFE, 0xB7]
    static let paddingLength = 16

    /// Port of `getCodecKey()` from the PB firmware, via pytboss's `timed_key`.
    /// The grill derives the same key from its own uptime, so the caller must
    /// pass a *fresh* `PB.GetTime` reading.
    public static func timedKey(uptime: Double) -> [UInt8] {
        var result: [UInt8] = []
        // The 10-second buffer is the firmware's tolerance for clock skew.
        var n = Int((max(uptime - 5, 0) / 10).rounded(.down))
        var key = Self.key
        while key.count > 1 {
            let v = key.remove(at: n % key.count)
            result.append(UInt8((Int(v) ^ n) & 0xFF))
            n = (n * Int(v) + Int(v)) & 0xFF
        }
        result.append(key[0])
        return result
    }

    /// Encodes `data`, prefixing the random padding + 0xFF sentinel the
    /// firmware strips on the other side. Output differs every call by design.
    public static func encode(_ data: [UInt8], key: [UInt8] = Codec.key) -> [UInt8] {
        var payload = (0..<paddingLength).map { _ in UInt8.random(in: 0...254) }
        payload.append(0xFF)
        payload.append(contentsOf: data)
        return transform(payload, key: key, feedback: .output)
    }

    /// Decodes `data` and drops everything up to and including the 0xFF
    /// sentinel. A payload with no sentinel is returned whole, matching pytboss.
    public static func decode(_ data: [UInt8], key: [UInt8] = Codec.key) -> [UInt8] {
        let plain = transform(data, key: key, feedback: .input)
        guard let sentinel = plain.firstIndex(of: 0xFF) else { return plain }
        return Array(plain[(sentinel + 1)...])
    }

    /// Which byte feeds back into the rolling key. Encode mixes in the byte it
    /// just produced, decode mixes in the byte it just consumed — both are the
    /// ciphertext, which is what makes the pair symmetric.
    private enum Feedback { case output, input }

    private static func transform(_ data: [UInt8], key: [UInt8], feedback: Feedback) -> [UInt8] {
        var key = key
        var result: [UInt8] = []
        result.reserveCapacity(data.count)
        for i in 0..<data.count {
            let k = key[i % key.count]
            let m = (data[i] ^ k) & 0xFF
            result.append(m)
            let k2 = (i + 1) % key.count
            let mixed = feedback == .output ? m : data[i]
            key[k2] = UInt8((Int(key[k2] ^ mixed) + i) & 0xFF)
        }
        return result
    }
}
