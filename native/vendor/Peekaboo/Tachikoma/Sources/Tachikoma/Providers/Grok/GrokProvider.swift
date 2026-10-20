import Foundation

/// Provider for Grok (xAI) models
@available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
public final class GrokProvider: ModelProvider {
    public let modelId: String
    public let baseURL: String?
    public let apiKey: String?
    public let capabilities: ModelCapabilities

    private let model: LanguageModel.Grok

    public init(model: LanguageModel.Grok, configuration: TachikomaConfiguration) throws {
        let modelId = model.modelId
        guard !Self.requiresResponsesAPIRouting(modelId) else {
            throw TachikomaError.unsupportedOperation(
                "\(modelId) requires xAI Responses API routing",
            )
        }

        self.model = model
        self.modelId = modelId
        self.baseURL = configuration.getBaseURL(for: .grok) ?? "https://api.x.ai/v1"

        // Get API key from configuration system (environment or credentials)
        if let key = configuration.getAPIKey(for: .grok) {
            self.apiKey = key
        } else {
            throw TachikomaError.authenticationFailed("X_AI_API_KEY or XAI_API_KEY not found")
        }

        self.capabilities = ModelCapabilities(
            supportsVision: model.supportsVision,
            supportsTools: model.supportsTools,
            supportsStreaming: true,
            contextLength: model.contextLength,
            maxOutputTokens: 4096,
        )
    }

    private static func requiresResponsesAPIRouting(_ modelId: String) -> Bool {
        let normalized = modelId.lowercased()
        let compact = normalized
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
        return normalized.contains("grok-4.20-multi-agent") ||
            normalized.contains("grok-4-20-multi-agent") ||
            compact.contains("grok420multiagent")
    }

    public func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        // Grok uses OpenAI-compatible API format - delegate to shared implementation
        try await OpenAICompatibleHelper.generateText(
            request: request,
            modelId: self.modelId,
            baseURL: self.baseURL!,
            apiKey: self.apiKey!,
            providerName: "Grok",
        )
    }

    public func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, Error> {
        // Grok uses OpenAI-compatible API format - delegate to shared implementation
        try await OpenAICompatibleHelper.streamText(
            request: request,
            modelId: self.modelId,
            baseURL: self.baseURL!,
            apiKey: self.apiKey!,
            providerName: "Grok",
        )
    }
}
