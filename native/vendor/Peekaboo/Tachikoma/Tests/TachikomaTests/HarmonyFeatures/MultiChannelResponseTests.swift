import Testing
@testable import Tachikoma

struct MultiChannelResponseTests {
    @Test
    func `ResponseChannel enum has all expected cases`() {
        let allCases = ResponseChannel.allCases
        #expect(allCases.count == 4)
        #expect(allCases.contains(.thinking))
        #expect(allCases.contains(.analysis))
        #expect(allCases.contains(.commentary))
        #expect(allCases.contains(.final))
    }

    @Test
    func `ResponseChannel raw values are correct`() {
        #expect(ResponseChannel.thinking.rawValue == "thinking")
        #expect(ResponseChannel.analysis.rawValue == "analysis")
        #expect(ResponseChannel.commentary.rawValue == "commentary")
        #expect(ResponseChannel.final.rawValue == "final")
    }

    @Test
    func `ModelMessage supports channel property`() {
        let message = ModelMessage(
            role: .assistant,
            content: [.text("This is my reasoning")],
            channel: .thinking,
        )

        #expect(message.channel == .thinking)
        #expect(message.role == .assistant)
        #expect(message.content.first == .text("This is my reasoning"))
    }

    @Test
    func `ModelMessage supports metadata property`() {
        let metadata = MessageMetadata(
            conversationId: "conv-123",
            turnId: "turn-456",
            customData: ["key": "value"],
        )

        let message = ModelMessage(
            role: .user,
            content: [.text("Hello")],
            metadata: metadata,
        )

        #expect(message.metadata?.conversationId == "conv-123")
        #expect(message.metadata?.turnId == "turn-456")
        #expect(message.metadata?.customData?["key"] == "value")
    }

    @Test
    func `TextStreamDelta supports channel events`() {
        // Channel information is now passed via the channel property, not event types
        let reasoningDelta = TextStreamDelta(
            type: .reasoning,
            content: "Analyzing the problem...",
            channel: .thinking,
        )

        let doneDelta = TextStreamDelta(
            type: .done,
            channel: .final,
        )

        let textDelta = TextStreamDelta(
            type: .textDelta,
            content: "Reasoning about the problem",
            channel: .thinking,
        )

        // Verify the event types and channels
        #expect(reasoningDelta.type == .reasoning)
        #expect(reasoningDelta.channel == .thinking)

        #expect(doneDelta.type == .done)
        #expect(doneDelta.channel == .final)

        #expect(textDelta.channel == .thinking)
        #expect(textDelta.content == "Reasoning about the problem")
    }

    @Test
    func `MessageMetadata equality`() {
        let metadata1 = MessageMetadata(
            conversationId: "123",
            turnId: "456",
            customData: ["key": "value"],
        )

        let metadata2 = MessageMetadata(
            conversationId: "123",
            turnId: "456",
            customData: ["key": "value"],
        )

        let metadata3 = MessageMetadata(
            conversationId: "789",
            turnId: "456",
            customData: ["key": "value"],
        )

        #expect(metadata1 == metadata2)
        #expect(metadata1 != metadata3)
    }

    @Test
    func `Legacy messages work without channel`() {
        // Old API still works
        let message = ModelMessage.user("Hello")

        #expect(message.channel == nil)
        #expect(message.metadata == nil)
        #expect(message.role == .user)
        #expect(message.content.first == .text("Hello"))
    }

    @Test
    func `Convenience initializers preserve nil channel`() {
        let systemMessage = ModelMessage.system("You are helpful")
        let userMessage = ModelMessage.user("Hello")
        let assistantMessage = ModelMessage.assistant("Hi there")

        #expect(systemMessage.channel == nil)
        #expect(userMessage.channel == nil)
        #expect(assistantMessage.channel == nil)
    }

    @Test
    func `Channel-aware message creation`() {
        let thinkingMessage = ModelMessage(
            role: .assistant,
            content: [.text("Let me think about this...")],
            channel: .thinking,
        )

        let analysisMessage = ModelMessage(
            role: .assistant,
            content: [.text("Analyzing the components...")],
            channel: .analysis,
        )

        let finalMessage = ModelMessage(
            role: .assistant,
            content: [.text("The answer is 42")],
            channel: .final,
        )

        #expect(thinkingMessage.channel == .thinking)
        #expect(analysisMessage.channel == .analysis)
        #expect(finalMessage.channel == .final)
    }

    @Test
    func `Codable conformance for ResponseChannel`() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let original = ResponseChannel.thinking
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ResponseChannel.self, from: data)

        #expect(decoded == original)

        // Check JSON string representation
        let jsonString = String(data: data, encoding: .utf8)
        #expect(jsonString == "\"thinking\"")
    }

    @Test
    func `Codable conformance for MessageMetadata`() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let original = MessageMetadata(
            conversationId: "conv-123",
            turnId: "turn-456",
            customData: ["foo": "bar", "baz": "qux"],
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(MessageMetadata.self, from: data)

        #expect(decoded == original)
        #expect(decoded.conversationId == "conv-123")
        #expect(decoded.turnId == "turn-456")
        #expect(decoded.customData?["foo"] == "bar")
    }
}
