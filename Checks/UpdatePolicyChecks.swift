import SottoCore

func checkUpdatePolicy() throws {
    func require(_ value: Bool, _ message: String) throws {
        if !value { throw ChatError.invalid(message) }
    }
    for enabled in [false, true] {
        for initializing in [false, true] {
            for busy in [false, true] {
                for content in [false, true] {
                    let actual = UpdatePolicy.installationDecision(enabled: enabled, initializing: initializing,
                                                                   busy: busy, hasEphemeralContent: content)
                    let expected: UpdateInstallationDecision
                    if !enabled { expected = .unavailable }
                    else if initializing { expected = .initializing }
                    else if busy { expected = .generatingAnswer }
                    else if content { expected = .confirmContentLoss }
                    else { expected = .allow }
                    try require(actual == expected, "update install policy must protect setup, generation and memory content")
                }
            }
        }
    }
}
