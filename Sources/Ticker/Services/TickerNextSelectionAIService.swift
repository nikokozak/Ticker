import Foundation

enum TickerNextSelectionAIAction: String {
    case send
    case sendWithPrompt = "send_with_prompt"
    case proofread
    case summarize

    func modifierPrompt(customInstruction: String?) throws -> String {
        switch self {
        case .send:
            return """
            Respond directly to the text.
            If it is a question, answer it.
            If it is an instruction, execute it.
            Return only the resulting text.
            """

        case .sendWithPrompt:
            guard let customInstruction = customInstruction?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !customInstruction.isEmpty else {
                throw TickerNextSelectionAIServiceError.missingSendInstruction
            }

            return """
            Apply this instruction to the text:
            \(customInstruction)

            Preserve factual meaning unless the instruction explicitly requests a change.
            Return only the transformed text.
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
    case missingSendInstruction
    case emptyModelResponse

    var errorDescription: String? {
        switch self {
        case .missingSendInstruction:
            return "Send with Prompt requires an instruction."
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
