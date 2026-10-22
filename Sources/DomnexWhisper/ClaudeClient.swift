import Foundation

enum ClaudeError: LocalizedError {
    case http(status: Int, message: String)
    case refused
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case let .http(status, message): return "API do Claude respondeu \(status): \(message)"
        case .refused: return "O Claude recusou o pedido."
        case .malformedResponse: return "Resposta inesperada da API do Claude."
        }
    }
}

/// Minimal Claude Messages API client over raw HTTP (there is no official Swift SDK).
/// Records the tokens of every response in `UsageTracker`.
struct ClaudeClient {
    let apiKey: String

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Sends one user message and returns the text of the reply.
    func complete(
        model: String,
        system: String,
        user: String,
        effort: String,
        timeout: TimeInterval
    ) async throws -> String {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "output_config": ["effort": effort],
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        // Server-side refusal fallback: if a safety classifier declines the request, the API
        // re-runs it on Anthropic's recommended fallback model. Haiku has no server-side fallback.
        if !model.contains("haiku") {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
            throw ClaudeError.http(
                status: status,
                message: apiError?.error.message ?? String(decoding: data.prefix(300), as: UTF8.self)
            )
        }

        guard let message = try? JSONDecoder().decode(MessageResponse.self, from: data) else {
            throw ClaudeError.malformedResponse
        }
        // Recorded before the refusal check: declined requests can still be billed. The response's
        // model is the one that answered, which differs from the request when a fallback ran.
        if let usage = message.usage {
            UsageTracker.shared.record(
                model: message.model ?? model,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens
            )
        }
        if message.stopReason == "refusal" {
            throw ClaudeError.refused
        }
        // Thinking and fallback blocks are skipped; only text blocks carry the answer.
        return message.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct MessageResponse: Decodable {
    struct Block: Decodable {
        let type: String
        let text: String?
    }

    struct Usage: Decodable {
        let inputTokens: Int
        let outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    let content: [Block]
    let stopReason: String?
    let model: String?
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case content, model, usage
        case stopReason = "stop_reason"
    }
}

private struct APIErrorEnvelope: Decodable {
    struct Detail: Decodable {
        let type: String
        let message: String
    }

    let error: Detail
}
