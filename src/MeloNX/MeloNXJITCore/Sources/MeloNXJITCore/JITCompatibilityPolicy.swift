public enum JITCompatibilityPolicy {
    public static func useBuiltIn(preference: Bool?, externalProviderSelected: Bool, pairedBuiltInAvailable: Bool = false) -> Bool {
        preference ?? (pairedBuiltInAvailable || !externalProviderSelected)
    }
    public static func useLegacyMapping(dynamicCodeSigning: Bool, appOnMac: Bool, majorOS: Int) -> Bool {
        dynamicCodeSigning || appOnMac || majorOS < 19
    }
}

/// Executed on the native serial queue. Pool allocation is process-scoped;
/// detach belongs to EACH attached debugger session, including a warm retry.
public enum JITMappingLifecycle {
    public static func run(poolReady: Bool, createProbe: () -> Bool, executeProbe: () -> Bool,
                           initializePool: () -> Bool, isTraced: () -> Bool?, detach: () -> Void) -> Bool {
        defer { if isTraced() == true { detach() } }
        if poolReady { return executeProbe() }
        guard createProbe(), executeProbe() else { return false }
        return initializePool()
    }
}
