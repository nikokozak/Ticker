import SwiftUI
import AppKit

private enum QuickPanelStyle {
    static let radius: CGFloat = 8
    static let badgeVerticalPadding: CGFloat = 2
    static let optionVerticalPadding: CGFloat = 5
    static let pickerMaxHeight: CGFloat = 180
    static let responseMaxHeight: CGFloat = 250
    static let progressSize: CGFloat = 16
    static let typingDotSize: CGFloat = 4
    static let markdownLineSpacing: CGFloat = 3
    static let inputInsetY: CGFloat = 2
    static let inputHeightPadding: CGFloat = 4
    static let minInputHeight: CGFloat = 22
    static let maxInputHeight: CGFloat = 120

    static let microTextSize: CGFloat = 9
    static let iconSize: CGFloat = 10
    static let captionSize: CGFloat = 11
    static let bodySize: CGFloat = 12
    static let inputSize: CGFloat = 15
    static let actionIconSize: CGFloat = 18

    static let surface = Color(
        light: Color(red: 251 / 255, green: 251 / 255, blue: 250 / 255),
        dark: Color(red: 28 / 255, green: 28 / 255, blue: 27 / 255)
    )
    static let surfaceRaised = Color(
        light: Color.white,
        dark: Color(red: 43 / 255, green: 43 / 255, blue: 41 / 255)
    )
    static let surfaceMuted = Color(
        light: Color(red: 244 / 255, green: 244 / 255, blue: 242 / 255),
        dark: Color(red: 48 / 255, green: 48 / 255, blue: 46 / 255)
    )
    static let text = Color(
        light: Color(red: 31 / 255, green: 31 / 255, blue: 29 / 255),
        dark: Color(red: 243 / 255, green: 242 / 255, blue: 237 / 255)
    )
    static let textMuted = Color(
        light: Color(red: 111 / 255, green: 111 / 255, blue: 104 / 255),
        dark: Color(red: 170 / 255, green: 167 / 255, blue: 157 / 255)
    )
    static let textSubtle = Color(
        light: Color(red: 155 / 255, green: 154 / 255, blue: 145 / 255),
        dark: Color(red: 119 / 255, green: 116 / 255, blue: 108 / 255)
    )
    static let accent = Color(
        light: Color(red: 37 / 255, green: 99 / 255, blue: 235 / 255),
        dark: Color(red: 138 / 255, green: 168 / 255, blue: 255 / 255)
    )
    static let success = Color(
        light: Color(red: 22 / 255, green: 129 / 255, blue: 61 / 255),
        dark: Color(red: 104 / 255, green: 185 / 255, blue: 130 / 255)
    )
    static let danger = Color(
        light: Color(red: 199 / 255, green: 58 / 255, blue: 50 / 255),
        dark: Color(red: 238 / 255, green: 127 / 255, blue: 118 / 255)
    )

    static func font(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(size: size, weight: weight, design: design)
    }
}

// MARK: - Content Height Preference Key

/// PreferenceKey for bubbling up content height from SwiftUI to the panel
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = QuickPanelWindow.minHeight
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// SwiftUI view for the Quick Panel content
/// Simplified for ticker-v2: capture mode only (no search, ask, command modes)
struct QuickPanelView: View {
    @ObservedObject var manager: QuickPanelManager
    @FocusState private var isInputFocused: Bool
    @State private var isPickerExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Ephemeral conversation response area (above everything else)
            if manager.ephemeralConversation.isActive {
                responseArea
            }

            // Error display
            if let error = manager.error {
                errorView(error)
            }

            // Status message (info/success feedback)
            if let status = manager.status {
                statusView(status)
            }

            // Stream destination picker and active-conversation controls
            headerRow

            // Context badge (if text/image was captured)
            if let context = manager.context, context.hasContent {
                contextBadge(context: context)
            }

            // Input field
            inputField

            // Mode hints bar at bottom
            modeHintsBar
        }
        .padding(Spacing.lg)
        .frame(width: QuickPanelWindow.defaultWidth, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(QuickPanelStyle.surfaceRaised)
        .background(
            GeometryReader { geometry in
                Color.clear
                    .preference(key: ContentHeightKey.self, value: geometry.size.height)
            }
        )
        .onPreferenceChange(ContentHeightKey.self) { height in
            Task { @MainActor in
                manager.contentHeightChanged(height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: QuickPanelStyle.radius))
        .overlay(
            RoundedRectangle(cornerRadius: QuickPanelStyle.radius)
                .stroke(Color.clear, lineWidth: 1)
        )
        .onReceive(NotificationCenter.default.publisher(for: .quickPanelDidShow)) { _ in
            isInputFocused = true
            isPickerExpanded = false
        }
    }

    // MARK: - Context Preview

    @ViewBuilder
    private func contextBadge(context: QuickPanelContext) -> some View {
        if let contextText = context.contextText {
            selectedTextContextPreview(context: context, selectedText: contextText)
        } else {
            attachmentContextBadge(context: context)
        }
    }

    private func selectedTextContextPreview(context: QuickPanelContext, selectedText: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "text.quote")
                .font(QuickPanelStyle.font(size: QuickPanelStyle.captionSize, weight: .medium))
                .foregroundColor(QuickPanelStyle.accent)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(selectedText)
                    .font(QuickPanelStyle.font(size: QuickPanelStyle.bodySize))
                    .foregroundColor(QuickPanelStyle.text)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let source = contextSourceLabel(context) {
                    Text(source)
                        .font(QuickPanelStyle.font(size: QuickPanelStyle.microTextSize))
                        .foregroundColor(QuickPanelStyle.textMuted)
                        .lineLimit(1)
                        .help(contextSourceFullLabel(context) ?? source)
                }
            }

            Spacer(minLength: Spacing.sm)

            clearContextButton
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .background(QuickPanelStyle.accent.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: QuickPanelStyle.radius)
                .stroke(QuickPanelStyle.accent.opacity(0.16), lineWidth: 1)
        )
        .cornerRadius(QuickPanelStyle.radius)
    }

    private func attachmentContextBadge(context: QuickPanelContext) -> some View {
        let isScreenshot = context.isScreenshot
        let accentColor = isScreenshot ? QuickPanelStyle.success : QuickPanelStyle.textMuted
        let backgroundColor = isScreenshot ? QuickPanelStyle.success.opacity(0.15) : QuickPanelStyle.accent.opacity(0.1)

        return HStack(spacing: Spacing.xs) {
            Image(systemName: context.hasImage ? "photo" : "text.quote")
                .font(QuickPanelStyle.font(size: QuickPanelStyle.iconSize))
                .foregroundColor(accentColor)

            Text(contextPreview(context))
                .font(QuickPanelStyle.font(size: QuickPanelStyle.captionSize))
                .foregroundColor(accentColor)
                .lineLimit(1)

            Spacer()

            if let app = context.activeApp {
                Text(app)
                    .font(QuickPanelStyle.font(size: QuickPanelStyle.microTextSize))
                    .foregroundColor(QuickPanelStyle.textMuted.opacity(0.7))
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, QuickPanelStyle.badgeVerticalPadding)
                    .background(QuickPanelStyle.surfaceMuted)
                    .cornerRadius(QuickPanelStyle.radius)
            }

            clearContextButton
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(backgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: QuickPanelStyle.radius)
                .stroke(isScreenshot ? QuickPanelStyle.success.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .cornerRadius(QuickPanelStyle.radius)
    }

    private var clearContextButton: some View {
        Button(action: { manager.clearContext() }) {
            Image(systemName: "xmark")
                .font(QuickPanelStyle.font(size: QuickPanelStyle.microTextSize, weight: .semibold))
                .foregroundColor(QuickPanelStyle.textMuted.opacity(0.6))
        }
        .buttonStyle(.plain)
        .disabled(manager.isInputSaveFeedbackActive)
        .help("Clear context")
    }

    private func contextPreview(_ context: QuickPanelContext) -> String {
        if context.isScreenshot {
            return "Screenshot attached"
        }
        if let text = context.contextText {
            if text.count > 40 {
                return String(text.prefix(37)) + "..."
            }
            return text
        }
        if context.hasImage {
            return "Image attached"
        }
        return "Context attached"
    }

    private func contextSourceLabel(_ context: QuickPanelContext) -> String? {
        let app = context.activeApp?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = context.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceApp = app?.isEmpty == false ? app : nil
        let sourceTitle = title.flatMap { $0.isEmpty ? nil : SourceShortTitle.derive(displayName: $0) }
        let baseLabel: String?

        switch (sourceApp, sourceTitle) {
        case let (sourceApp?, sourceTitle?):
            baseLabel = "\(sourceApp) — \(sourceTitle)"
        case let (sourceApp?, nil):
            baseLabel = sourceApp
        case let (nil, sourceTitle?):
            baseLabel = sourceTitle
        case (nil, nil):
            baseLabel = nil
        }

        let isClipboardText = context.selectionCaptureOutcome == .clipboard || context.isClipboardTextContext
        guard isClipboardText else {
            return baseLabel
        }

        return "\(baseLabel ?? "Copied text") · from clipboard"
    }

    private func contextSourceFullLabel(_ context: QuickPanelContext) -> String? {
        let app = context.activeApp?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = context.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceApp = app?.isEmpty == false ? app : nil
        let sourceTitle = title?.isEmpty == false ? title : nil

        switch (sourceApp, sourceTitle) {
        case let (sourceApp?, sourceTitle?):
            return "\(sourceApp) — \(sourceTitle)"
        case let (sourceApp?, nil):
            return sourceApp
        case let (nil, sourceTitle?):
            return sourceTitle
        case (nil, nil):
            return nil
        }
    }

    // MARK: - Stream Destination Picker

    private var headerRow: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            streamDestinationPicker

            Spacer(minLength: Spacing.sm)

            if manager.ephemeralConversation.isActive {
                clearConversationButton
                    .padding(.top, 1)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: manager.ephemeralConversation.isActive)
    }

    private var clearConversationButton: some View {
        Button(action: { manager.clearEphemeralConversation() }) {
            Image(systemName: "xmark.circle")
                .font(QuickPanelStyle.font(size: QuickPanelStyle.captionSize, weight: .semibold))
                .foregroundColor(QuickPanelStyle.textMuted.opacity(0.72))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Clear conversation")
        .accessibilityLabel("Clear conversation")
    }

    private var streamDestinationPicker: some View {
        let isSaveFeedbackActive = manager.isStreamPickerSaveFeedbackActive
        let pickerBackground = isSaveFeedbackActive
            ? QuickPanelStyle.success.opacity(0.16)
            : QuickPanelStyle.surfaceMuted
        let pickerStroke = isSaveFeedbackActive
            ? QuickPanelStyle.success.opacity(0.34)
            : Color.clear

        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Button(action: {
                withAnimation(.easeOut(duration: 0.12)) {
                    isPickerExpanded.toggle()
                }
            }) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(QuickPanelStyle.font(size: QuickPanelStyle.captionSize))
                        .foregroundColor(QuickPanelStyle.textMuted)
                    Text(selectedStreamTitle)
                        .font(QuickPanelStyle.font(size: QuickPanelStyle.captionSize))
                        .foregroundColor(QuickPanelStyle.textMuted)
                        .lineLimit(1)
                    Image(systemName: isPickerExpanded ? "chevron.up" : "chevron.down")
                        .font(QuickPanelStyle.font(size: QuickPanelStyle.microTextSize, weight: .semibold))
                        .foregroundColor(QuickPanelStyle.textSubtle)
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(pickerBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: QuickPanelStyle.radius)
                        .stroke(pickerStroke, lineWidth: 1)
                )
                .cornerRadius(QuickPanelStyle.radius)
            }
            .buttonStyle(.plain)

            if isPickerExpanded {
                streamDestinationOptions
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.6), value: manager.isStreamPickerSaveFeedbackActive)
    }

    private var streamDestinationOptions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(manager.availableStreams, id: \.id) { stream in
                    streamOptionButton(title: stream.title, isSelected: manager.selectedStreamId == stream.id) {
                        manager.selectedStreamId = stream.id
                        isPickerExpanded = false
                    }
                }

                if !manager.availableStreams.isEmpty {
                    Divider()
                        .padding(.vertical, QuickPanelStyle.badgeVerticalPadding)
                }

                streamOptionButton(title: "New Stream...", systemImage: "plus", isSelected: false) {
                    manager.createAndSelectNewStream()
                    isPickerExpanded = false
                }
            }
            .padding(Spacing.xs)
        }
        .frame(maxHeight: QuickPanelStyle.pickerMaxHeight)
        .background(QuickPanelStyle.surfaceRaised)
        .overlay(
            RoundedRectangle(cornerRadius: QuickPanelStyle.radius)
                .stroke(QuickPanelStyle.textMuted.opacity(0.16), lineWidth: 1)
        )
        .cornerRadius(QuickPanelStyle.radius)
    }

    private func streamOptionButton(
        title: String,
        systemImage: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(QuickPanelStyle.font(size: QuickPanelStyle.iconSize, weight: .semibold))
                        .foregroundColor(QuickPanelStyle.textMuted)
                }

                Text(title)
                    .font(QuickPanelStyle.font(size: QuickPanelStyle.captionSize))
                    .foregroundColor(QuickPanelStyle.textMuted)
                    .lineLimit(1)

                Spacer(minLength: Spacing.sm)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(QuickPanelStyle.font(size: QuickPanelStyle.iconSize, weight: .semibold))
                        .foregroundColor(QuickPanelStyle.accent)
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, QuickPanelStyle.optionVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var selectedStreamTitle: String {
        if let id = manager.selectedStreamId,
           let stream = manager.availableStreams.first(where: { $0.id == id }) {
            return stream.title
        }
        return "Select stream..."
    }

    // MARK: - Ephemeral Conversation Response Area

    private var responseArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(Array(manager.ephemeralConversation.turns.enumerated()), id: \.offset) { index, turn in
                        turnView(turn, id: index)
                    }

                    // Currently streaming response
                    if manager.ephemeralConversation.isStreaming {
                        streamingResponseView
                            .id("streaming")
                    }
                }
                .padding(Spacing.sm)
            }
            .frame(maxHeight: QuickPanelStyle.responseMaxHeight)
            .background(QuickPanelStyle.surfaceMuted.opacity(0.3))
            .cornerRadius(QuickPanelStyle.radius)
            .onChange(of: manager.ephemeralConversation.currentResponse) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }
            .onChange(of: manager.ephemeralConversation.turns.count) { _, _ in
                if let lastIndex = manager.ephemeralConversation.turns.indices.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func turnView(_ turn: ConversationTurn, id: Int) -> some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            VStack(alignment: .leading, spacing: 2) {
                // Role indicator
                Text(turn.role == .user ? "You" : "AI")
                    .font(QuickPanelStyle.font(size: QuickPanelStyle.microTextSize, weight: .medium))
                    .foregroundColor(QuickPanelStyle.textSubtle)

                Text(verbatim: turn.content)
                    .font(QuickPanelStyle.font(size: QuickPanelStyle.bodySize))
                    .foregroundColor(turn.role == .assistant ? QuickPanelStyle.text : QuickPanelStyle.textMuted)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            saveConversationMessageButton(turn: turn)
        }
        .padding(.vertical, Spacing.xs)
        .id(id)
    }

    private func saveConversationMessageButton(turn: ConversationTurn) -> some View {
        let content = turn.saveContent ?? turn.content
        return Button(action: { manager.saveConversationMessage(turn) }) {
            Image(systemName: "tray.and.arrow.down")
                .font(QuickPanelStyle.font(size: QuickPanelStyle.iconSize, weight: .semibold))
                .foregroundColor(QuickPanelStyle.textMuted.opacity(0.64))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Save message to stream")
        .accessibilityLabel("Save message to stream")
        .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var streamingResponseView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("AI")
                .font(QuickPanelStyle.font(size: QuickPanelStyle.microTextSize, weight: .medium))
                .foregroundColor(QuickPanelStyle.textSubtle)

            if manager.ephemeralConversation.currentResponse.isEmpty {
                // Typing indicator when waiting for first chunk
                TypingDotsView()
                    .padding(.vertical, Spacing.xs)
            } else {
                HStack(alignment: .bottom, spacing: 0) {
                    Text(verbatim: manager.ephemeralConversation.currentResponse)
                        .font(QuickPanelStyle.font(size: QuickPanelStyle.bodySize))
                        .foregroundColor(QuickPanelStyle.text)
                        .textSelection(.enabled)
                    Text(" ●")
                        .font(QuickPanelStyle.font(size: QuickPanelStyle.iconSize))
                        .foregroundColor(QuickPanelStyle.accent)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    // MARK: - Input Field

    private var inputField: some View {
        let isInputDisabled = manager.isLoading ||
            manager.ephemeralConversation.isStreaming ||
            manager.isInputSaveFeedbackActive

        return HStack(spacing: Spacing.sm) {
            QuickPanelInputField(
                text: $manager.inputText,
                placeholder: placeholderText,
                isLoading: isInputDisabled,
                isShimmering: manager.isInputSaveFeedbackActive,
                onSubmit: handleSubmit,
                onCancel: { manager.handleEscape() },
                onCmdEnter: handleCmdSubmit,
                onOptionEnter: handleOptionSubmit
            )

            if manager.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: QuickPanelStyle.progressSize, height: QuickPanelStyle.progressSize)
            } else {
                Button(action: handleSubmit) {
                    Image(systemName: "plus.circle.fill")
                        .font(QuickPanelStyle.font(size: QuickPanelStyle.actionIconSize))
                        .foregroundColor(canSubmit ? QuickPanelStyle.accent : QuickPanelStyle.textSubtle.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit || manager.isInputSaveFeedbackActive)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(QuickPanelStyle.surfaceMuted)
        .cornerRadius(QuickPanelStyle.radius)
    }

    private var placeholderText: String {
        if manager.context?.hasContent == true {
            return "Add a note..."
        }
        return "Capture a thought..."
    }

    private var canSubmit: Bool {
        let hasInput = !manager.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasContext = manager.context?.hasContent == true
        return hasInput || hasContext
    }

    // MARK: - Mode Hints Bar

    private var modeHintsBar: some View {
        HStack(spacing: Spacing.md) {
            Text("↵ save")
                .font(QuickPanelStyle.font(size: QuickPanelStyle.microTextSize))
                .foregroundColor(QuickPanelStyle.textMuted.opacity(0.6))

            Text("⌘↵ AI+save")
                .font(QuickPanelStyle.font(size: QuickPanelStyle.microTextSize))
                .foregroundColor(QuickPanelStyle.textMuted.opacity(0.6))

            Text("⌥↵ ask")
                .font(QuickPanelStyle.font(size: QuickPanelStyle.microTextSize))
                .foregroundColor(QuickPanelStyle.textMuted.opacity(0.6))

            Spacer()
        }
        .padding(.horizontal, Spacing.xs)
    }

    // MARK: - Error View

    private func errorView(_ error: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(QuickPanelStyle.font(size: QuickPanelStyle.iconSize))
                .foregroundColor(QuickPanelStyle.danger)

            Text(error)
                .font(QuickPanelStyle.font(size: QuickPanelStyle.captionSize))
                .foregroundColor(QuickPanelStyle.danger)
                .lineLimit(2)
        }
        .padding(Spacing.sm)
        .background(QuickPanelStyle.danger.opacity(0.1))
        .cornerRadius(QuickPanelStyle.radius)
    }

    // MARK: - Status View

    private func statusView(_ status: QuickPanelStatus) -> some View {
        let icon: String
        let color: Color
        let textColor: Color

        switch status.tone {
        case .warning:
            icon = "info.circle"
            color = QuickPanelStyle.textMuted
            textColor = QuickPanelStyle.textMuted
        case .info:
            icon = "info.circle"
            color = QuickPanelStyle.textMuted
            textColor = QuickPanelStyle.text
        case .success:
            icon = "checkmark.circle"
            color = QuickPanelStyle.success
            textColor = QuickPanelStyle.text
        }

        return HStack(spacing: Spacing.xs) {
            Image(systemName: icon)
                .font(QuickPanelStyle.font(size: QuickPanelStyle.iconSize))
                .foregroundColor(color)

            Text(status.message)
                .font(QuickPanelStyle.font(size: QuickPanelStyle.captionSize))
                .foregroundColor(textColor)
                .lineLimit(2)

            Spacer(minLength: Spacing.xs)

            if let action = status.action {
                Button(action: { manager.performStatusAction(action) }) {
                    HStack(spacing: QuickPanelStyle.badgeVerticalPadding) {
                        Image(systemName: "gearshape")
                            .font(QuickPanelStyle.font(size: QuickPanelStyle.microTextSize, weight: .semibold))
                        Text("Open Settings")
                            .font(QuickPanelStyle.font(size: QuickPanelStyle.microTextSize, weight: .medium))
                    }
                    .foregroundColor(QuickPanelStyle.accent)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, QuickPanelStyle.badgeVerticalPadding)
                    .background(QuickPanelStyle.surfaceRaised)
                    .cornerRadius(QuickPanelStyle.radius)
                }
                .buttonStyle(.plain)
                .help("Open Accessibility settings")
                .accessibilityLabel("Open Accessibility settings")
            }
        }
        .padding(Spacing.sm)
        .background(color.opacity(0.1))
        .cornerRadius(QuickPanelStyle.radius)
    }

    // MARK: - Actions

    private func handleSubmit() {
        guard canSubmit, !manager.isLoading, !manager.isInputSaveFeedbackActive else { return }
        Task {
            await manager.handleEnter()
        }
    }

    private func handleCmdSubmit() {
        guard canSubmit, !manager.isLoading, !manager.isInputSaveFeedbackActive else { return }
        Task {
            await manager.handleCmdEnter()
        }
    }

    private func handleOptionSubmit() {
        let hasInput = !manager.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasInput,
              !manager.isLoading,
              !manager.ephemeralConversation.isStreaming,
              !manager.isInputSaveFeedbackActive else { return }
        Task {
            await manager.handleOptionEnter()
        }
    }
}

// MARK: - Quick Panel Input Field (NSTextView wrapper)

struct QuickPanelInputField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isLoading: Bool
    var isShimmering: Bool
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onCmdEnter: (() -> Void)?
    var onOptionEnter: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = QuickPanelTextView()
        textView.coordinator = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.usesRuler = false

        // Appearance
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: QuickPanelStyle.inputSize, weight: .regular)
        textView.textColor = NSColor(QuickPanelStyle.text)
        textView.placeholder = placeholder

        // Text container - enable word wrapping
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.lineBreakMode = .byWordWrapping

        // Sizing behavior
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        // Remove focus ring and insets
        textView.focusRingType = .none
        textView.textContainerInset = NSSize(width: 0, height: QuickPanelStyle.inputInsetY)

        textView.string = text
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        scrollView.documentView = textView

        // Calculate initial height
        DispatchQueue.main.async {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            context.coordinator.updateScrollViewHeight()
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? QuickPanelTextView else { return }

        context.coordinator.isLoading = isLoading
        textView.placeholder = placeholder
        textView.setShimmering(isShimmering)

        // Update text if changed externally
        if textView.string != text {
            textView.string = text
            if text.isEmpty {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
            DispatchQueue.main.async {
                context.coordinator.updateScrollViewHeight()
            }
        }

        textView.isEditable = !isLoading
        textView.needsDisplay = true
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: QuickPanelInputField
        weak var textView: QuickPanelTextView?
        weak var scrollView: NSScrollView?
        var isLoading: Bool = false

        init(_ parent: QuickPanelInputField) {
            self.parent = parent
        }

        func updateScrollViewHeight() {
            guard let textView = textView,
                  let scrollView = scrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer
            else { return }

            layoutManager.ensureLayout(for: textContainer)

            let lineHeight = ceil(layoutManager.defaultLineHeight(for: textView.font ?? NSFont.systemFont(ofSize: QuickPanelStyle.inputSize)))
            let usedHeight = ceil(layoutManager.usedRect(for: textContainer).height)
            var height = max(usedHeight, lineHeight)

            if !textView.string.isEmpty && textView.string.hasSuffix("\n") {
                height += lineHeight
            }

            let paddedHeight = height + QuickPanelStyle.inputHeightPadding
            let finalHeight = min(
                max(paddedHeight, QuickPanelStyle.minInputHeight),
                QuickPanelStyle.maxInputHeight
            )

            if let heightConstraint = scrollView.constraints.first(where: { $0.firstAttribute == .height }) {
                heightConstraint.constant = finalHeight
            } else {
                let constraint = scrollView.heightAnchor.constraint(equalToConstant: finalHeight)
                constraint.priority = .defaultHigh
                constraint.isActive = true
            }

            scrollView.invalidateIntrinsicContentSize()
            scrollView.needsLayout = true
        }

        func textDidBeginEditing(_ notification: Notification) {
            textView?.needsDisplay = true
        }

        func textDidEndEditing(_ notification: Notification) {
            textView?.needsDisplay = true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? QuickPanelTextView else { return }

            parent.text = textView.string
            textView.needsDisplay = true

            updateScrollViewHeight()
        }
    }
}

// MARK: - Custom NSTextView for Quick Panel

class QuickPanelTextView: NSTextView {
    weak var coordinator: QuickPanelInputField.Coordinator?
    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }
    private var shimmerTimer: Timer?
    private var shimmerStartedAt: Date?

    deinit {
        stopShimmer()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopShimmer()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, !placeholder.isEmpty else { return }

        let placeholderAttributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: QuickPanelStyle.inputSize),
            .foregroundColor: NSColor(QuickPanelStyle.textSubtle)
        ]
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height
        )
        placeholder.draw(at: origin, withAttributes: placeholderAttributes)
    }

    func setShimmering(_ enabled: Bool) {
        if enabled {
            startShimmer()
        } else {
            stopShimmer()
        }
    }

    private func startShimmer() {
        guard shimmerTimer == nil else { return }
        shimmerStartedAt = Date()

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self, let startedAt = self.shimmerStartedAt else {
                timer.invalidate()
                return
            }

            let progress = min(Date().timeIntervalSince(startedAt) / 0.7, 1)
            let pulse = CGFloat(sin(progress * .pi))
            self.applyTextColor(self.shimmerColor(pulse: pulse))

            if progress >= 1 {
                self.stopShimmer()
            }
        }

        shimmerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopShimmer() {
        shimmerTimer?.invalidate()
        shimmerTimer = nil
        shimmerStartedAt = nil
        applyTextColor(NSColor(QuickPanelStyle.text))
    }

    private func shimmerColor(pulse: CGFloat) -> NSColor {
        let base = NSColor(QuickPanelStyle.text)
        let highlight = NSColor(QuickPanelStyle.textMuted)
        return base.blended(withFraction: 0.35 * pulse, of: highlight) ?? base
    }

    private func applyTextColor(_ color: NSColor) {
        textColor = color
        typingAttributes[.foregroundColor] = color

        let length = (string as NSString).length
        guard length > 0 else { return }
        textStorage?.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: length))
    }

    override func keyDown(with event: NSEvent) {
        // Escape - cancel
        if event.keyCode == 53 {
            coordinator?.parent.onCancel()
            return
        }

        // Enter/Return
        if event.keyCode == 36 {
            if event.modifierFlags.contains(.command) {
                coordinator?.parent.onCmdEnter?()
                return
            }
            if event.modifierFlags.contains(.option) {
                coordinator?.parent.onOptionEnter?()
                return
            }
            // Plain Enter submits
            coordinator?.parent.onSubmit()
            return
        }

        super.keyDown(with: event)
    }
}

// MARK: - Typing Indicator

/// Three dots pulsing in a staggered wave while waiting for the first AI chunk.
private struct TypingDotsView: View {
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: QuickPanelStyle.typingDotSize) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(QuickPanelStyle.textSubtle)
                    .frame(width: QuickPanelStyle.typingDotSize, height: QuickPanelStyle.typingDotSize)
                    .opacity(pulsing ? 1 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: pulsing
                    )
            }
        }
        .onAppear { pulsing = true }
    }
}

// MARK: - Markdown Rendering

/// Renders markdown content with code block support
private struct MarkdownContentView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(parseBlocks(content)) { block in
                switch block {
                case .text(let text):
                    MarkdownTextView(text: text)
                case .code(let lang, let code):
                    CodeBlockView(language: lang, code: code)
                }
            }
        }
    }

    private func parseBlocks(_ input: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        if input.isEmpty { return [] }

        let components = input.components(separatedBy: "```")

        for (index, component) in components.enumerated() {
            if index % 2 == 0 {
                // Text block
                let trimmed = component.trimmingCharacters(in: .newlines)
                if !trimmed.isEmpty {
                    blocks.append(.text(trimmed))
                }
            } else {
                // Code block - first line is language
                let lines = component.components(separatedBy: .newlines)
                let lang = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
                let code = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines)
                blocks.append(.code(lang.isEmpty ? nil : lang, code))
            }
        }
        return blocks
    }
}

/// Renders inline markdown text using AttributedString
private struct MarkdownTextView: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            Text(attributed)
                .font(QuickPanelStyle.font(size: QuickPanelStyle.bodySize))
                .foregroundColor(QuickPanelStyle.text)
                .lineSpacing(QuickPanelStyle.markdownLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else {
            Text(text)
                .font(QuickPanelStyle.font(size: QuickPanelStyle.bodySize))
                .foregroundColor(QuickPanelStyle.text)
                .lineSpacing(QuickPanelStyle.markdownLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// Renders a fenced code block with optional language label
private struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lang = language, !lang.isEmpty {
                HStack {
                    Text(lang.uppercased())
                        .font(QuickPanelStyle.font(size: QuickPanelStyle.microTextSize, weight: .bold, design: .monospaced))
                        .foregroundColor(QuickPanelStyle.textMuted)
                    Spacer()
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(QuickPanelStyle.surfaceMuted)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(QuickPanelStyle.font(size: QuickPanelStyle.captionSize, design: .monospaced))
                    .foregroundColor(QuickPanelStyle.text)
                    .padding(Spacing.sm)
                    .textSelection(.enabled)
            }
        }
        .background(QuickPanelStyle.surfaceMuted.opacity(0.5))
        .cornerRadius(QuickPanelStyle.radius)
    }
}

/// Content block type for markdown parsing
private enum ContentBlock: Identifiable {
    case text(String)
    case code(String?, String)

    var id: String {
        switch self {
        case .text(let s): return "text-\(s.hashValue)"
        case .code(_, let c): return "code-\(c.hashValue)"
        }
    }
}
