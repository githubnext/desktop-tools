import Foundation
import Testing
@testable import Tachikoma

@Suite(.serialized)
struct TestHelpersTests {
    @Test
    func `helper create configuration`() {
        let config = TestHelpers.createTestConfiguration(apiKeys: ["openai": "test-key"])
        let expected = TestHelpers.standardTestKeys["openai"]

        #expect(config.getAPIKey(for: .openai) == expected)
        #expect(config.hasConfiguredAPIKey(for: .openai))
    }

    @Test
    func `helper with empty configuration`() async {
        let result = await TestHelpers.withEmptyTestConfiguration { config in
            config.getAPIKey(for: .openai)
        }

        // Should be nil in empty configuration
        #expect(result == nil)
    }

    @Test
    func `helper with standard test configuration`() async {
        let result = await TestHelpers.withStandardTestConfiguration { config in
            config.getAPIKey(for: .openai)
        }

        #expect(result == "test-key")
    }

    @Test
    func `helper with selective configuration`() async {
        let result = await TestHelpers.withSelectiveTestConfiguration(present: ["openai"]) { config in
            (config.getAPIKey(for: .openai), config.getAPIKey(for: .anthropic))
        }

        #expect(result.0 == "test-key")
        #expect(result.1 == nil)
    }
}
