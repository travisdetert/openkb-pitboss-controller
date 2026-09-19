import Foundation
import os

/// One log, in one place.
///
/// The desktop app funnels main + renderer output into `/tmp/openkb-pit-boss.log`
/// so debugging never means "open DevTools and paste the error". A phone has no
/// terminal to tail, so the same idea lands as: every subsystem writes here, the
/// file lives in Application Support, and the Diagnostics screen can show it and
/// hand it to the share sheet. Debugging a cook that went wrong should not
/// require Xcode and a cable.
public enum PitBossLog {
    private static let subsystem = "com.openkb.pit-boss"
    private static let logger = Logger(subsystem: subsystem, category: "grill")

    /// Bound so a long cook can't fill the device; the tail is what matters.
    private static let maxBytes = 512 * 1024

    private static let queue = DispatchQueue(label: "\(subsystem).log")
    private static var handle: FileHandle?

    public static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("openkb-pit-boss.log")
    }()

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func write(_ message: String) {
        logger.log("\(message, privacy: .public)")
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if handle == nil {
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: fileURL)
                _ = try? handle?.seekToEnd()
            }
            try? handle?.write(contentsOf: data)
            rotateIfNeeded()
        }
    }

    /// Keeps the most recent half of the file when it outgrows the cap.
    private static func rotateIfNeeded() {
        guard let size = try? handle?.offset(), size > maxBytes else { return }
        handle = nil
        guard let existing = try? Data(contentsOf: fileURL) else { return }
        let keep = existing.suffix(maxBytes / 2)
        try? keep.write(to: fileURL)
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }

    /// The log's contents, for the Diagnostics screen and the share sheet.
    public static func contents() -> String {
        queue.sync {
            try? handle?.synchronize()
            return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }
    }

    public static func clear() {
        queue.sync {
            handle = nil
            try? Data().write(to: fileURL)
        }
    }
}
