import Foundation

enum TickerNextSelectionAIAction: String {
    case rewrite
    case proofread
    case summarize

    func modifierPrompt(customInstruction: String?) throws -> String {
        switch self {
        case .rewrite:
            guard let customInstruction = customInstruction?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !customInstruction.isEmpty else {
                throw TickerNextSelectionAIServiceError.missingRewriteInstruction
            }

            return """
            Rewrite the text to satisfy this instruction:
            \(customInstruction)

            Preserve factual meaning unless the instruction explicitly requests a change.
            Return only the rewritten text.
            """

        case .proofread:
            return """
            Proofread the text.
            Fix grammar, punctuation, spelling, and obvious clarity issues.
            Preserve meaning and tone. Return only the corrected text.
            """

        case .summarize:
            return """
            Summarize the text while preserving the key facts and conclusions.
            Keep it concise and readable. Return only the summary.
            """
        }
    }
}

enum TickerNextSelectionAIServiceError: LocalizedError {
    case missingRewriteInstruction
    case emptyModelResponse

    var errorDescription: String? {
        switch self {
        case .missingRewriteInstruction:
            return "Rewrite requires an instruction."
        case .emptyModelResponse:
            return "AI returned an empty response."
        }
    }
}

final class TickerNextSelectionAIService {
    private let proxyService: ProxyLLMService

    init(proxyService: ProxyLLMService = ProxyLLMService()) {
        self.proxyService = proxyService
    }

    func transformSelection(
        _ selection: String,
        action: TickerNextSelectionAIAction,
        customInstruction: String? = nil
    ) async throws -> String {
        let modifierPrompt = try action.modifierPrompt(customInstruction: customInstruction)

        return try await withCheckedThrowingContinuation { continuation in
            var responseBuffer = ""
            var didResume = false

            Task {
                await proxyService.applyModifier(
                    currentContent: selection,
                    modifierPrompt: modifierPrompt,
                    onChunk: { chunk in
                        responseBuffer += chunk
                    },
                    onComplete: {
                        guard !didResume else { return }
                        didResume = true

                        let output = responseBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !output.isEmpty else {
                            continuation.resume(throwing: TickerNextSelectionAIServiceError.emptyModelResponse)
                            return
                        }

                        continuation.resume(returning: output)
                    },
                    onError: { error in
                        guard !didResume else { return }
                        didResume = true
                        continuation.resume(throwing: error)
                    }
                )
            }
        }
    }
}
