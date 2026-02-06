import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics

/// Onboarding view shown on first launch
struct OnboardingView: View {
    @State private var step: OnboardingStep = .welcome
    @State private var hasAccessibility = false
    @State private var isPromptingAccessibility = false
    @State private var hasScreenRecording = false
    @State private var isPromptingScreenRecording = false

    var onComplete: () -> Void

    enum OnboardingStep {
        case welcome
        case accessibility
        case screenRecording
        case complete
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { index in
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
                case .screenRecording:
                    screenRecordingStep
                case .complete:
                    completeStep
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 420, height: 380)
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .onAppear { refreshPermissionState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // When returning from System Settings, refresh permission state so the UI updates.
            refreshPermissionState()
        }
    }

    private var stepIndex: Int {
        switch step {
        case .welcome: return 0
        case .accessibility: return 1
        case .screenRecording: return 2
        case .complete: return 3
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
                Button("Grant Access") {
                    guard !isPromptingAccessibility else { return }
                    isPromptingAccessibility = true
                    grantAccessibilityAccess()
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
                    withAnimation { step = .screenRecording }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Button(hasAccessibility ? "Continue" : "Continue") {
                    withAnimation { step = .screenRecording }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { checkAccessibility() }
    }

    // MARK: - Screen Recording Step

    private var screenRecordingStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.inset.filled.and.cursorarrow")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Screen Recording Permission")
                .font(.system(size: 20, weight: .semibold))

            Text("Ticker needs Screen Recording permission to capture screenshots when you press Cmd+;.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("After enabling, you may need to restart Ticker for it to take effect.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("If Ticker isn’t listed, click “+” and add Ticker manually.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if hasScreenRecording {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Permission granted")
                        .foregroundColor(.green)
                }
                .font(.system(size: 14, weight: .medium))
            } else {
                Button("Grant Access") {
                    guard !isPromptingScreenRecording else { return }
                    isPromptingScreenRecording = true
                    grantScreenRecordingAccess()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        isPromptingScreenRecording = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isPromptingScreenRecording)

                Button("Open System Settings") {
                    _ = openSystemSettingsPrivacyPane(.screenRecording)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 12) {
                Button("Skip for now") {
                    withAnimation { step = .complete }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Button("Continue") {
                    withAnimation { step = .complete }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { checkScreenRecording() }
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

    private func checkScreenRecording() {
        hasScreenRecording = CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    private func requestScreenRecording() -> Bool {
        let granted = CGRequestScreenCaptureAccess()

        // Poll for permission change (may still require restart, but this keeps UI honest when it updates).
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if CGPreflightScreenCaptureAccess() {
                hasScreenRecording = true
                timer.invalidate()
            }
        }

        return granted
    }

    private func refreshPermissionState() {
        hasAccessibility = AXIsProcessTrusted()
        hasScreenRecording = CGPreflightScreenCaptureAccess()
    }

    private enum SystemSettingsPrivacyPane: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
    }

    /// Open System Settings directly to avoid cross-talk/ordering issues between permission prompts.
    /// Falls back to the OS prompt-based APIs if deep-linking fails for any reason.
    private func openSystemSettingsPrivacyPane(_ pane: SystemSettingsPrivacyPane) -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private func grantAccessibilityAccess() {
        if !openSystemSettingsPrivacyPane(.accessibility) {
            requestAccessibility()
        } else {
            // Poll so the UI updates when the user toggles the permission.
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                if AXIsProcessTrusted() {
                    hasAccessibility = true
                    timer.invalidate()
                }
            }
        }
    }

    private func grantScreenRecordingAccess() {
        // Calling CGRequestScreenCaptureAccess is what registers Ticker with macOS so it
        // shows up in the Screen Recording list. Deep-linking alone is not sufficient.
        if CGPreflightScreenCaptureAccess() {
            hasScreenRecording = true
            return
        }

        // Important: don't open System Settings ourselves here. macOS will show a system
        // prompt with an "Open System Settings" button; opening both simultaneously is
        // confusing and can make it look like Ticker isn't listed yet.
        _ = requestScreenRecording()
    }

}
