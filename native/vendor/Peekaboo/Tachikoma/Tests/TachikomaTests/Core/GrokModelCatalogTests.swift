import Foundation
import Testing
@testable import Tachikoma

struct GrokModelCatalogTests {
    private static let catalog: [Model.Grok] = [
        .grok43,
        .grok420Reasoning,
        .grok420NonReasoning,
    ]

    private func requireModernPlatforms(_ body: () throws -> Void) rethrows {
        if #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *) {
            try body()
        } else {
            Issue.record("ModelSelector requires macOS 13.0+ / iOS 16.0+")
        }
    }

    @Test
    func `CaseIterable reflects the official Grok catalog`() {
        self.requireModernPlatforms {
            #expect(Model.Grok.allCases == Self.catalog)
        }
    }

    @Test
    func `ModelSelector parses every Grok model identifier`() throws {
        try self.requireModernPlatforms {
            for model in Self.catalog {
                let parsed = try ModelSelector.parseModel(model.modelId)
                #expect(parsed == .grok(model))
            }
            #expect(try ModelSelector.parseModel("grok-4.3-latest") == .grok(.grok43))
        }
    }

    @Test
    func `Available-model CLI listing matches catalog IDs`() {
        self.requireModernPlatforms {
            let listed = Set(ModelSelector.availableModels(for: "grok"))
            let expected = Set(Self.catalog.map(\.modelId))
            #expect(listed == expected)
        }
    }

    @Test
    func `Grok model vision support matches current xAI catalog`() {
        self.requireModernPlatforms {
            #expect(Model.grok(.grok43).supportsVision)
            #expect(Model.grok(.grok420Reasoning).supportsVision)
            #expect(Model.grok(.grok420NonReasoning).supportsVision)
            #expect(Model.grok(.grok420MultiAgent).supportsVision == false)
            #expect(Model.grok(.grok420MultiAgent).supportsTools == false)
        }
    }

    @Test
    func `ModelSelector preserves server-redirected Grok identifiers`() throws {
        try self.requireModernPlatforms {
            for id in [
                "grok-4-0709",
                "grok-3",
                "grok-2-1212",
                "grok-4-fast",
                "grok-code-fast-1",
            ] {
                let parsed = try ModelSelector.parseModel(id)
                #expect(parsed == .grok(.custom(id)))
            }
        }
    }

    @Test
    func `ModelSelector keeps provider-qualified Grok slugs on xAI`() throws {
        try self.requireModernPlatforms {
            let parsed = try ModelSelector.parseModel("xai/grok-code-fast-1")

            #expect(parsed == .grok(.custom("grok-code-fast-1")))
        }
    }

    @Test
    func `ModelSelector rejects unsupported Grok multi-agent identifiers`() {
        self.requireModernPlatforms {
            for id in [
                "grok-4.20-multi-agent-0309",
                "grok420multiagent",
                "xai/grok-4.20-multi-agent",
            ] {
                #expect(throws: ModelValidationError.self) {
                    _ = try ModelSelector.parseModel(id)
                }
            }
        }
    }

    @Test
    func `Grok provider rejects multi-agent until Responses routing exists`() {
        self.requireModernPlatforms {
            let config = TachikomaConfiguration(apiKeys: ["grok": "test-key"])

            #expect(throws: TachikomaError.self) {
                _ = try ProviderFactory.createProvider(for: .grok(.grok420MultiAgent), configuration: config)
            }
            #expect(throws: TachikomaError.self) {
                _ = try GrokProvider(model: .grok420MultiAgent, configuration: config)
            }
            #expect(throws: TachikomaError.self) {
                _ = try GrokProvider(model: .custom("grok420multiagent"), configuration: config)
            }
        }
    }
}
