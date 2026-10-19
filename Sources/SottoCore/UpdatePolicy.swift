/// Installing an update restarts the process; conversation content is memory-only.
public enum UpdateInstallationDecision: Equatable {
    case unavailable
    case initializing
    case generatingAnswer
    case confirmContentLoss
    case allow
}

public enum UpdatePolicy {
    public static func installationDecision(enabled: Bool, initializing: Bool, busy: Bool,
                                            hasEphemeralContent: Bool) -> UpdateInstallationDecision {
        guard enabled else { return .unavailable }
        if initializing { return .initializing }
        if busy { return .generatingAnswer }
        return hasEphemeralContent ? .confirmContentLoss : .allow
    }
}
