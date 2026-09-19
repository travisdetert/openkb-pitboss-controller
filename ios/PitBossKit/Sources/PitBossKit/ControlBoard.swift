import Foundation
import JavaScriptCore

/// Errors raised while building or running a board routine.
public enum ControlBoardError: Error, LocalizedError {
    case scriptFailed(String)
    case notImplemented(String)
    case badResult(String)

    public var errorDescription: String? {
        switch self {
        case .scriptFailed(let m):   return "Control board script failed: \(m)"
        case .notImplemented(let m): return "Control board routine unavailable: \(m)"
        case .badResult(let m):      return "Control board returned an unusable value: \(m)"
        }
    }
}

/// One control-board command. Most are a fixed hex string; the two that take a
/// temperature are a JavaScript body that builds one.
public struct BoardCommand: Sendable {
    public let name: String
    public let slug: String
    public let hex: String?
    public let jsBody: String?
}

/// A control board (PBL, PBC, PBV, …) and its command + parsing routines.
///
/// The per-model routines ship as JavaScript inside `grills.json` — that is how
/// Pit Boss distributes them, and pytboss runs them through a JS interpreter
/// rather than reimplementing 19 boards by hand. This port does the same with
/// JavaScriptCore, a system framework on both iOS and macOS. Porting the
/// routines to Swift would mean re-deriving every board's parser and silently
/// diverging from upstream the moment a model is added.
///
/// Unlike pytboss we do **not** scrub the JavaScript. pytboss rewrites `let`/
/// `const` to `var` and arrow functions to `function` because duktape is ES5
/// only; JavaScriptCore is a full modern engine, so the routines run as shipped.
public final class ControlBoard: @unchecked Sendable {
    public let name: String
    public let commands: [String: BoardCommand]

    private let statusJS: String?
    private let temperaturesJS: String?

    /// One context per board, reused across calls. JSContext is not thread-safe,
    /// so every entry point funnels through this lock.
    private let context = JSContext()!
    private let lock = NSLock()

    /// Helpers injected around a command body, mirroring pytboss's template.
    private static let commandPreamble = """
    var formatHex = function(n) {
        var t = '0' + parseInt(n).toString(16);
        return t.substring(t.length - 2);
    };
    var formatDecimal = function(n) {
        var t = '000' + parseInt(n).toString(10);
        return t.substring(t.length - 3);
    };
    """

    /// Helpers injected around a parse body, mirroring pytboss's template.
    private static let parsePreamble = """
    var convertTemperature = function(parts, startIndex) {
        var temp = (
            parts[startIndex] * 100 +
            parts[startIndex + 1] * 10 +
            parts[startIndex + 2]
        );
        return temp === 960 ? null : temp;
    };
    var parseHexMessage = function(data) {
        var parsed = [];
        for (var i = 0; i < data.length; i += 2) {
            parsed.push(parseInt(data.substring(i, i + 2), 16));
        }
        return parsed;
    };
    """

    init(name: String, commands: [String: BoardCommand], statusJS: String?, temperaturesJS: String?) {
        self.name = name
        self.commands = commands
        self.statusJS = statusJS
        self.temperaturesJS = temperaturesJS
    }

    // MARK: - Commands

    /// Builds the hex command string for `slug`, running its JS body if it has one.
    public func command(_ slug: String, _ args: [Int] = []) throws -> String {
        guard let cmd = commands[slug] else {
            throw ControlBoardError.notImplemented("no command '\(slug)' on board \(name)")
        }
        if let hex = cmd.hex, !hex.isEmpty { return hex }
        guard let body = cmd.jsBody, !body.isEmpty else {
            throw ControlBoardError.notImplemented("command '\(slug)' has neither hex nor a body")
        }

        // The bodies read `arguments[0]`, so this must be a real function.
        let script = """
        (function() {
            return function() {
                \(Self.commandPreamble)
                \(body)
            };
        })()
        """
        let result = try run(script, arguments: args.map { NSNumber(value: $0) },
                             describing: "command '\(slug)'")
        guard let result, result.isString, let hex = result.toString(), !hex.isEmpty else {
            throw ControlBoardError.badResult("command '\(slug)' did not return a hex string")
        }
        return hex
    }

    // MARK: - Parsing

    /// Parses an FE0B status frame. Returns nil when the board's routine rejects it.
    public func parseStatus(_ message: String) throws -> ParsedFrame? {
        guard let js = statusJS, !js.isEmpty else {
            throw ControlBoardError.notImplemented("board \(name) has no status routine")
        }
        return try parse(js, message: message, describing: "status")
    }

    /// Parses an FE0C temperatures frame. Returns nil when the routine rejects it.
    public func parseTemperatures(_ message: String) throws -> ParsedFrame? {
        guard let js = temperaturesJS, !js.isEmpty else {
            throw ControlBoardError.notImplemented("board \(name) has no temperature routine")
        }
        return try parse(js, message: message, describing: "temperatures")
    }

    private func parse(_ body: String, message: String, describing what: String) throws -> ParsedFrame? {
        let script = """
        (function() {
            return function(message) {
                \(Self.parsePreamble)
                \(body)
            };
        })()
        """
        let result = try run(script, arguments: [message], describing: "\(what) parser")
        guard let result else {
            throw ControlBoardError.badResult("\(what) parser produced no value")
        }
        if result.isNull || result.isUndefined { return nil }
        guard let dict = result.toDictionary() as? [String: Any] else {
            throw ControlBoardError.badResult("\(what) parser did not return an object")
        }
        return Self.decode(dict)
    }

    /// Turns the JS object into a `GrillState`, recording which keys were present.
    ///
    /// A key whose value is JS `null` (an unplugged probe) stays in
    /// `reportedKeys` with a nil value — the board said "nothing there", which
    /// is different from not mentioning the field at all.
    static func decode(_ dict: [String: Any]) -> ParsedFrame {
        var state = GrillState()
        var keys = Set<String>()

        func bool(_ key: String, _ path: WritableKeyPath<GrillState, Bool?>) {
            guard let raw = dict[key] else { return }
            keys.insert(key)
            state[keyPath: path] = (raw as? NSNumber)?.boolValue
        }
        func int(_ key: String, _ path: WritableKeyPath<GrillState, Int?>) {
            guard let raw = dict[key] else { return }
            keys.insert(key)
            state[keyPath: path] = (raw as? NSNumber)?.intValue
        }

        bool("moduleIsOn", \.moduleIsOn)
        bool("err1", \.err1); bool("err2", \.err2); bool("err3", \.err3)
        bool("highTempErr", \.highTempErr); bool("fanErr", \.fanErr)
        bool("hotErr", \.hotErr); bool("motorErr", \.motorErr)
        bool("noPellets", \.noPellets); bool("erL", \.erL)
        bool("fanState", \.fanState); bool("hotState", \.hotState)
        bool("motorState", \.motorState); bool("lightState", \.lightState)
        bool("primeState", \.primeState); bool("isFahrenheit", \.isFahrenheit)

        int("recipeStep", \.recipeStep); int("recipeTime", \.recipeTime)
        int("p1Target", \.p1Target); int("p1Temp", \.p1Temp)
        int("p2Temp", \.p2Temp); int("p3Temp", \.p3Temp); int("p4Temp", \.p4Temp)
        int("grillSetTemp", \.grillSetTemp); int("grillTemp", \.grillTemp)
        int("smokerActTemp", \.smokerActTemp)

        return ParsedFrame(state: state, reportedKeys: keys)
    }

    // MARK: - JSContext plumbing

    /// Evaluates `script` to a function and calls it, holding the lock across
    /// the whole sequence. JSContext is not thread-safe and a JSValue is only
    /// valid while its context is quiescent, so evaluate, call, and the
    /// exception check cannot be split into separately-locked steps.
    private func run(_ script: String, arguments: [Any], describing what: String) throws -> JSValue? {
        lock.lock()
        defer { lock.unlock() }

        context.exception = nil
        guard let fn = context.evaluateScript(script) else {
            throw ControlBoardError.scriptFailed("\(what): script produced no value")
        }
        if let ex = context.exception {
            context.exception = nil
            throw ControlBoardError.scriptFailed("\(what): \(ex.toString() ?? "unknown")")
        }
        guard fn.isObject else {
            throw ControlBoardError.badResult("\(what): script did not produce a function")
        }

        let result = fn.call(withArguments: arguments)
        if let ex = context.exception {
            context.exception = nil
            throw ControlBoardError.scriptFailed("\(what): \(ex.toString() ?? "unknown")")
        }
        return result
    }
}
