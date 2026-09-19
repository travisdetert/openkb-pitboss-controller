import Foundation

/// The grill's reported state.
///
/// Every field is optional because no single frame carries all of them: the
/// FE0B status frame reports flags and the recipe step, FE0C reports
/// temperatures. `merged(with:)` is what turns the two streams into one view —
/// the same merge the desktop app's sidecar does.
public struct GrillState: Equatable, Sendable, Codable {
    // Module
    public var moduleIsOn: Bool?

    // Error flags
    public var err1: Bool?
    public var err2: Bool?
    public var err3: Bool?
    public var highTempErr: Bool?
    public var fanErr: Bool?
    public var hotErr: Bool?
    public var motorErr: Bool?
    public var noPellets: Bool?
    public var erL: Bool?

    // Component activity
    public var fanState: Bool?
    public var hotState: Bool?    // igniter / hot rod
    public var motorState: Bool?  // auger
    public var lightState: Bool?
    public var primeState: Bool?

    // Recipe
    public var recipeStep: Int?
    public var recipeTime: Int?   // seconds remaining

    // Temperatures — Fahrenheit when `isFahrenheit`
    public var p1Target: Int?
    public var p1Temp: Int?
    public var p2Temp: Int?
    public var p3Temp: Int?
    public var p4Temp: Int?
    public var grillSetTemp: Int?
    public var grillTemp: Int?
    public var smokerActTemp: Int?
    public var isFahrenheit: Bool?

    public init() {}

    /// Returns a copy with every field `other` actually reported overlaid.
    ///
    /// A probe that reads 960 decodes to `nil` ("not plugged in"), which is a
    /// real observation — but it arrives as an absent key, indistinguishable
    /// from "this frame doesn't carry that field". `reportedKeys` is what keeps
    /// the two apart, so unplugging a probe clears it instead of freezing the
    /// last reading on screen.
    public func merged(with other: GrillState, reportedKeys: Set<String>) -> GrillState {
        var out = self
        func take<T>(_ key: String, _ path: WritableKeyPath<GrillState, T?>) {
            guard reportedKeys.contains(key) else { return }
            out[keyPath: path] = other[keyPath: path]
        }
        take("moduleIsOn", \.moduleIsOn)
        take("err1", \.err1); take("err2", \.err2); take("err3", \.err3)
        take("highTempErr", \.highTempErr); take("fanErr", \.fanErr)
        take("hotErr", \.hotErr); take("motorErr", \.motorErr)
        take("noPellets", \.noPellets); take("erL", \.erL)
        take("fanState", \.fanState); take("hotState", \.hotState)
        take("motorState", \.motorState); take("lightState", \.lightState)
        take("primeState", \.primeState)
        take("recipeStep", \.recipeStep); take("recipeTime", \.recipeTime)
        take("p1Target", \.p1Target); take("p1Temp", \.p1Temp)
        take("p2Temp", \.p2Temp); take("p3Temp", \.p3Temp); take("p4Temp", \.p4Temp)
        take("grillSetTemp", \.grillSetTemp); take("grillTemp", \.grillTemp)
        take("smokerActTemp", \.smokerActTemp); take("isFahrenheit", \.isFahrenheit)
        return out
    }

    /// True when any error flag is raised.
    public var hasError: Bool {
        [err1, err2, err3, highTempErr, fanErr, hotErr, motorErr, noPellets, erL]
            .contains { $0 == true }
    }
}

/// The result of parsing one frame: the decoded state plus exactly which keys
/// the board reported, so a `nil` temperature can be distinguished from a field
/// the frame never mentions.
public struct ParsedFrame: Equatable, Sendable {
    public let state: GrillState
    public let reportedKeys: Set<String>
}
