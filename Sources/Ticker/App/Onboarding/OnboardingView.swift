import SwiftUI
import ApplicationServices

/// Onboarding view shown on first launch
struct OnboardingView: View {
    @State private var step: OnboardingStep = .welcome
    @State private var hasAccessibility = false
    @State private var isPromptingAccessibility = false

    var onComplete: () -> Void

    enum OnboardingStep {
        case welcome
        case accessibility
        case complete
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(stepIndex >= index ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 32)

            // Step content
            Group {
                switch step {
                case .welcome:
                    welcomeStep
                case .accessibility:
                    accessibilityStep
                case .complete:
                    completeStep
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 420, height: 380)
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }

    private var stepIndex: Int {
        switch step {
        case .welcome: return 0
        case .accessibility: return 1
        case .complete: return 2
        }
    }

    // MARK: - Welcome Step

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "text.quote")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)

            Text("Welcome to Ticker")
                .font(.system(size: 24, weight: .semibold))

            Text("A research companion that captures and connects your thoughts.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("To enable AI features, you’ll enter a Device Key in Settings (Ticker Proxy).")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            Button("Get Started") {
                withAnimation { step = .accessibility }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Accessibility Step

    private var accessibilityStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Accessibility Permission")
                .font(.system(size: 20, weight: .semibold))

            Text("Ticker needs Accessibility permission to capture text selections when you press Cmd+L.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if hasAccessibility {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Permission granted")
                        .foregroundColor(.green)
                }
                .font(.system(size: 14, weight: .medium))
            } else {
                Button("Open System Settings") {
                    guard !isPromptingAccessibility else { return }
                    isPromptingAccessibility = true
                    requestAccessibility()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        isPromptingAccessibility = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isPromptingAccessibility)
            }

            Spacer()

            HStack(spacing: 12) {
                Button("Skip for now") {
                    withAnimation { step = .complete }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Button(hasAccessibility ? "Continue" : "Continue") {
                    withAnimation { step = .complete }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { checkAccessibility() }
    }

    // MARK: - Complete Step

    private var completeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.green)

            Text("You're all set!")
                .font(.system(size: 24, weight: .semibold))

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "command")
                        .frame(width: 20)
                    Text("Cmd+L")
                        .fontWeight(.medium)
                    Text("Open Quick Panel anywhere")
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "command")
                        .frame(width: 20)
                    Text("Cmd+;")
                        .fontWeight(.medium)
                    Text("Capture a screenshot")
                        .foregroundColor(.secondary)
                }
            }
            .font(.system(size: 13))
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

            Text("You can enter or update your Device Key in Settings at any time.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            Spacer()

            Button("Start Using Ticker") {
                SettingsService.shared.hasCompletedOnboarding = true
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Actions

    private func checkAccessibility() {
        hasAccessibility = AXIsProcessTrusted()
    }

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        // Poll for permission change
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if AXIsProcessTrusted() {
                hasAccessibility = true
                timer.invalidate()
            }
        }
    }

}
