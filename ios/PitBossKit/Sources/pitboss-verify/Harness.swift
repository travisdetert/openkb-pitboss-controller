import Foundation

/// A deliberately small check harness.
///
/// This exists instead of XCTest because XCTest ships inside Xcode: a test
/// target cannot run on a machine with only Command Line Tools, which is
/// exactly where the protocol layer most needs checking. Failures are collected
/// rather than fatal so one bad vector doesn't hide the rest.
final class Harness {
    private(set) var passed = 0
    private(set) var failures: [String] = []
    private var group = ""

    func section(_ name: String) {
        group = name
        print("\n\u{001B}[1m\(name)\u{001B}[0m")
    }

    func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if condition {
            passed += 1
        } else {
            let m = "\(group): \(message())"
            failures.append(m)
            print("  \u{001B}[31m✗\u{001B}[0m \(m)")
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ what: @autoclosure () -> String) {
        check(actual == expected, "\(what()) — got \(actual), want \(expected)")
    }

    func notNil<T>(_ value: T?, _ what: @autoclosure () -> String) -> T? {
        check(value != nil, "\(what()) — unexpectedly nil")
        return value
    }

    func isNil<T>(_ value: T?, _ what: @autoclosure () -> String) {
        check(value == nil, "\(what()) — expected nil, got \(String(describing: value))")
    }

    func throwsError<T>(_ what: String, _ body: () throws -> T) {
        do {
            let v = try body()
            check(false, "\(what) — expected a throw, got \(v)")
        } catch {
            passed += 1
        }
    }

    func noThrow<T>(_ what: @autoclosure () -> String, _ body: () throws -> T) {
        do {
            _ = try body()
            passed += 1
        } catch {
            check(false, "\(what()) — threw \(error)")
        }
    }

    /// Prints the tally and returns the process exit code.
    func finish() -> Int32 {
        print("")
        if failures.isEmpty {
            print("\u{001B}[32m✓ \(passed) checks passed\u{001B}[0m")
            return 0
        }
        print("\u{001B}[31m✗ \(failures.count) failed, \(passed) passed\u{001B}[0m")
        for f in failures { print("    \(f)") }
        return 1
    }
}

/// Minimal JSON value so a vector's expected state can hold ints, bools and nulls.
enum JSONValue: Decodable, Equatable, CustomStringConvertible {
    case int(Int), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON scalar") }
    }

    var description: String {
        switch self {
        case .int(let v):  return String(v)
        case .bool(let v): return String(v)
        case .null:        return "null"
        }
    }
}

extension Array where Element == UInt8 {
    init(hex: String) {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
            out.append(UInt8(hex[i..<j], radix: 16) ?? 0)
            i = j
        }
        self = out
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
