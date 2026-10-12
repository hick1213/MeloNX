/// Native touch IDs remain unchanged while their corresponding fingers are down.
public struct StableTouchIdentifiers<Touch: Hashable> {
    private var identifiers: [Touch: Int] = [:]
    private var nextIdentifier = 0
    public init() {}
    public mutating func begin(_ touch: Touch) -> Int {
        if let existing = identifiers[touch] { return existing }
        while identifiers.values.contains(nextIdentifier) { advanceIdentifier() }
        let id = nextIdentifier
        advanceIdentifier()
        identifiers[touch] = id
        return id
    }
    private mutating func advanceIdentifier() {
        nextIdentifier = nextIdentifier == Int(Int32.max) ? 0 : nextIdentifier + 1
    }
    public func identifier(for touch: Touch) -> Int? { identifiers[touch] }
    public mutating func end(_ touch: Touch) -> Int? { identifiers.removeValue(forKey: touch) }
    public mutating func reset() -> [Int] {
        let active = identifiers.values.sorted()
        identifiers.removeAll()
        nextIdentifier = 0
        return active
    }
}
