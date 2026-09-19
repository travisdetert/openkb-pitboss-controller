import Foundation

/// One stage of a multi-step method.
public struct MethodStep: Identifiable, Equatable, Sendable {
    public var id: String { "\(title)-\(detail.prefix(24))" }
    public let title: String
    public let detail: String
    /// Roughly how long this stage runs, where the method specifies it.
    public let minutes: Int?
    /// Grill temperature for this stage, when it differs from the method's.
    public let grillTemp: Int?

    public init(_ title: String, _ detail: String, minutes: Int? = nil, grillTemp: Int? = nil) {
        self.title = title
        self.detail = detail
        self.minutes = minutes
        self.grillTemp = grillTemp
    }
}

/// A named technique for cooking a cut — the "how", where the target
/// temperature alone doesn't capture it.
///
/// 3-2-1 ribs and 0-400 wings aren't different temperatures, they're different
/// *procedures*, and the procedure is what people actually look up. A target of
/// 203° tells you nothing about when to wrap.
public struct CookMethod: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    /// One line: what it is and why you'd use it.
    public let summary: String
    public let steps: [MethodStep]
    /// The temperature the method runs at, where it's constant.
    public let grillTemp: Int?
    public let note: String?

    public init(_ name: String, _ summary: String, steps: [MethodStep],
                grillTemp: Int? = nil, note: String? = nil) {
        self.name = name
        self.summary = summary
        self.steps = steps
        self.grillTemp = grillTemp
        self.note = note
    }

    /// Total time where every stage declares one.
    public var totalMinutes: Int? {
        let known = steps.compactMap(\.minutes)
        return known.count == steps.count ? known.reduce(0, +) : nil
    }

    public var durationLabel: String? {
        guard let total = totalMinutes else { return nil }
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "~\(h)h" : "~\(h)h \(m)m"
    }
}

public extension CookMethod {

    /// Named lookups into the shared catalogue.
    ///
    /// These used to be Swift literals. Once `cooking.json` became the source
    /// of truth (ADR 0007) keeping both would have been two definitions of the
    /// same method, free to drift — so these resolve by name instead. A missing
    /// one means the data file is broken, which should fail loudly at the point
    /// of use rather than silently behave differently.
    static func named(_ name: String) -> CookMethod {
        guard let method = MeatCatalog.methods.first(where: { $0.name == name }) else {
            fatalError("cooking.json has no method named '\(name)'")
        }
        return method
    }

    static var threeTwoOne: CookMethod { named("3-2-1") }
    static var twoTwoOne: CookMethod { named("2-2-1") }
    static var zeroTo400: CookMethod { named("0 to 400") }
    static var texasCrutch: CookMethod { named("Texas crutch") }
    static var reverseSear: CookMethod { named("Reverse sear") }
    static var spatchcock: CookMethod { named("Spatchcock") }
    static var hotAndFast: CookMethod { named("Hot and fast") }
}
