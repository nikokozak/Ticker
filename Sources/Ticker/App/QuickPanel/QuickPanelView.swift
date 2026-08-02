import SwiftUI
import AppKit

private enum QuickPanelStyle {
    static let radius: CGFloat = 9
    static let panelRadius: CGFloat = 14
    static let badgeVerticalPadding: CGFloat = 2
    static let optionVerticalPadding: CGFloat = 5
    static let pickerMaxHeight: CGFloat = 180
    static let responseMaxHeight: CGFloat = 250
    static let progressSize: CGFloat = 16
    static let typingDotSize: CGFloat = 4
    static let markdownLineSpacing: CGFloat = 3
    static let inputInsetY: CGFloat = 2
    static let inputHeightPadding: CGFloat = 4
    static let minInputHeight: CGFloat = 24
    static let maxInputHeight: CGFloat = 144

    static let microTextSize: CGFloat = 10
    static let iconSize: CGFloat = 11
    static let captionSize: CGFloat = 12
    static let bodySize: CGFloat = 13
    static let inputSize: CGFloat = 16
    static let actionIconSize: CGFloat = 19

    static let surfaceRaised = Color(NativePalette.surfaceRaised)
    static let surfaceMuted = Color(NativePalette.surface)
    static let text = Color(NativePalette.text)
    static let textMuted = Color(NativePalette.textMuted)
    static let textSubtle = Color(NativePalette.textSubtle)
    static let accent = Color(NativePalette.accent)
    static let success = Color(NativePalette.success)
    static let danger = Color(NativePalette.danger)
    static let separator = Color(NativePalette.separator)

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
    @State private var isPickerExpanded = false
    @State private var inputFocusRequest = 0
    @State private var savedConversationTurns = Set<Int>()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
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
        .clipShape(RoundedRectangle(cornerRadius: QuickPanelStyle.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: QuickPanelStyle.panelRadius)
                .stroke(QuickPanelStyle.separator, lineWidth: 1)
        )
        .onReceive(NotificationCenter.default.publisher(for: .quickPanelWillShow)) { _ in
            isPickerExpanded = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickPanelDidShow)) { _ in
            inputFocusRequest &+= 1
        }
        .onChange(of: manager.ephemeralConversation.turns.isEmpty) { _, isEmpty in
            if isEmpty {
                savedConversationTurns.removeAll()
            }
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
        HStack(spacing: Spacing.xs) {
            Image(systemName: context.hasImage ? "photo" : "text.quote")
                .font(QuickPanelStyle.font(size: QuickPanelStyle.iconSize))
                .foregroundColor(QuickPanelStyle.textMuted)

            Text(contextPreview(context))
                .font(QuickPanelStyle.font(size: QuickPanelStyle.captionSize))
                .foregroundColor(QuickPanelStyle.textMuted)
                .lineLimit(1)

            Spacer()

            if let app = context.activeApp {
                Text(app)
                    .font(QuickPanelStyle.font(size: QuickPanelStyle.microTextSize))
                    .foregroundColor(QuickPanelStyle.textMuted)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, QuickPanelStyle.badgeVerticalPadding)
                    .background(QuickPanelStyle.surfaceMuted)
                    .cornerRadius(QuickPanelStyle.radius)
            }

            clearContextButton
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(QuickPanelStyle.accent.opacity(0.1))
        .cornerRadius(QuickPanelStyle.radius)
    }

    private var clearContextButton: some View {
        Button(action: { manager.clearContext() }) {
            Image(systemName: "xmark")
                .font(QuickPanelStyle.font(size: QuickPanelStyle.microTextSize, weight: .semibold))
                .foregroundColor(QuickPanelStyle.textMuted)
        }
        .buttonStyle(.plain)
        .help("Clear context")
        .accessibilityLabel("Clear attached context")
    }

    private func contextPreview(_ context: QuickPanelContext) -> String {
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

        return baseLabel
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
        Button(action: {
            savedConversationTurns.removeAll()
            manager.clearEphemeralConversation()
        }) {
            Image(systemName: "xmark.circle")
                .font(QuickPanelStyle.font(size: QuickPanelStyle.captionSize, weight: .semibold))
                .foregroundColor(QuickPanelStyle.textMuted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Clear conversation")
        .accessibilityLabel("Clear conversation")
    }

    private var streamDestinationPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Button(action: {
                withAnimation(.easeOut(duration: 0.12)) {
                    isPickerExpanded.toggle()
                }
            }) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(QuickPanelStyle.font(size: QuickPanelStyle.captionSize))
                        .foregroundColor(QuickPanelStyle.textMuted)
                    Text("Save to")
                        .font(QuickPanelStyle.font(size: QuickPanelStyle.captionSize))
                        .foregroundColor(QuickPanelStyle.textMuted)
                    Text(selectedStreamTitle)
                        .font(QuickPanelStyle.font(size: QuickPanelStyle.captionSize, weight: .medium))
                        .foregroundColor(QuickPanelStyle.text)
                        .lineLimit(1)
                    Image(systemName: isPickerExpanded ? "chevron.up" : "chevron.down")
                        .font(QuickPanelStyle.font(size: QuickPanelStyle.microTextSize, weight: .semibold))
                        .foregroundColor(QuickPanelStyle.textMuted)
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(QuickPanelStyle.surfaceMuted)
                .cornerRadius(QuickPanelStyle.radius)
            }
            .buttonStyle(.plain)
            .help("Choose destination stream")
            .accessibilityLabel("Destination: \(selectedStreamTitle)")

            if isPickerExpanded {
                streamDestinationOptions
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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
        return "New Stream"
    }

    private var compactStreamTitle: String {
        selectedStreamTitle.count > 24
            ? "\(selectedStreamTitle.prefix(23))…"
            : selectedStreamTitle
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
        let roleLabel = turn.role == .assistant
            ? "AI"
            : turn.contextIncluded ? "You · context included" : "You"
        return HStack(alignment: .top, spacing: Spacing.xs) {
            VStack(alignment: .leading, spacing: 2) {
                // Role indicator
                Text(roleLabel)
                    .font(QuickPanelStyle.font(size: QuickPanelStyle.microTextSize, weight: .medium))
                    .foregroundColor(QuickPanelStyle.textMuted)

                Text(verbatim: turn.content)
                    .font(QuickPanelStyle.font(size: QuickPanelStyle.bodySize))
                    .foregroundColor(turn.role == .assistant ? QuickPanelStyle.text : QuickPanelStyle.textMuted)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            saveConversationMessageButton(turn: turn, id: id)
        }
        .padding(.vertical, Spacing.xs)
        .id(id)
    }

    private func saveConversationMessageButton(turn: ConversationTurn, id: Int) -> some View {
        let content = turn.saveContent ?? turn.content
        let isSaved = savedConversationTurns.contains(id)
        return Button(action: {
            if manager.saveConversationMessage(turn) {
                savedConversationTurns.insert(id)
            }
        }) {
            Image(systemName: isSaved ? "checkmark" : "tray.and.arrow.down")
                .font(QuickPanelStyle.font(size: QuickPanelStyle.iconSize, weight: .semibold))
                .foregroundColor(isSaved ? QuickPanelStyle.success : QuickPanelStyle.textMuted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isSaved)
        .help(isSaved ? "Saved to stream" : "Save message to stream")
        .accessibilityLabel(isSaved ? "Saved to stream" : "Save message to stream")
        .disabled(isSaved || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var streamingResponseView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("AI")
                .font(QuickPanelStyle.font(size: QuickPanelStyle.microTextSize, weight: .medium))
                .foregroundColor(QuickPanelStyle.textMuted)

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
            manager.ephemeralConversation.isStreaming

        return HStack(spacing: Spacing.sm) {
            QuickPanelInputField(
                text: $manager.inputText,
                placeholder: placeholderText,
                isLoading: isInputDisabled,
                focusRequest: inputFocusRequest,
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
                .disabled(!canSubmit)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .help("Save note")
                .accessibilityLabel("Save note")
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(QuickPanelStyle.surfaceMuted)
        .cornerRadius(QuickPanelStyle.radius)
    }

    private var placeholderText: String {
        if manager.context?.hasContent == true {
            return "Add a note…"
        }
        return "Capture a thought…"
    }

    private var canSubmit: Bool {
        let hasInput = !manager.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasContext = manager.context?.hasContent == true
        return hasInput || hasContext
    }

    // MARK: - Mode Hints Bar

    @ViewBuilder
    private var modeHintsBar: some View {
        if let confirmation = manager.saveConfirmation {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(QuickPanelStyle.font(size: QuickPanelStyle.iconSize, weight: .semibold))
                Text(confirmation)
                    .font(QuickPanelStyle.font(size: QuickPanelStyle.captionSize, weight: .medium))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundColor(QuickPanelStyle.success)
            .padding(.horizontal, Spacing.xs)
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.md) {
                    Text("↵  Save to \(compactStreamTitle)")
                    Text("⌘↵  Save + develop")
                    Spacer(minLength: 0)
                }
                Text("⌘V  Paste into note · ⌥↵  Chat here (not saved) · Esc closes, draft kept")
            }
            .font(QuickPanelStyle.font(size: QuickPanelStyle.microTextSize))
            .foregroundColor(QuickPanelStyle.textMuted)
            .lineLimit(1)
            .padding(.horizontal, Spacing.xs)
        }
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
        guard canSubmit, !manager.isLoading else { return }
        Task {
            await manager.handleEnter()
        }
    }

    private func handleCmdSubmit() {
        guard canSubmit, !manager.isLoading else { return }
        Task {
            await manager.handleCmdEnter()
        }
    }

    private func handleOptionSubmit() {
        let hasInput = !manager.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasInput,
              !manager.isLoading,
              !manager.ephemeralConversation.isStreaming else { return }
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
    var focusRequest: Int
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
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? QuickPanelTextView else { return }

        context.coordinator.parent = self
        context.coordinator.isLoading = isLoading
        textView.placeholder = placeholder

        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }

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
        var lastFocusRequest: Int

        init(_ parent: QuickPanelInputField) {
            self.parent = parent
            self.lastFocusRequest = parent.focusRequest
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

enum QuickPanelReturnAction: Equatable {
    case save
    case saveAndDevelop
    case ask
    case insertNewline

    init(modifierFlags: NSEvent.ModifierFlags) {
        let shortcutFlags = modifierFlags.intersection([.shift, .control, .option, .command])

        if shortcutFlags.isEmpty {
            self = .save
        } else if shortcutFlags == .command {
            self = .saveAndDevelop
        } else if shortcutFlags == .option {
            self = .ask
        } else {
            self = .insertNewline
        }
    }
}

class QuickPanelTextView: NSTextView {
    weak var coordinator: QuickPanelInputField.Coordinator?
    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, !placeholder.isEmpty else { return }

        let placeholderAttributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: QuickPanelStyle.inputSize),
            .foregroundColor: NSColor(QuickPanelStyle.textMuted)
        ]
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height
        )
        placeholder.draw(at: origin, withAttributes: placeholderAttributes)
    }

    override func keyDown(with event: NSEvent) {
        // Escape - cancel
        if event.keyCode == 53 {
            coordinator?.parent.onCancel()
            return
        }

        // Enter/Return
        if event.keyCode == 36 {
            switch QuickPanelReturnAction(modifierFlags: event.modifierFlags) {
            case .save:
                coordinator?.parent.onSubmit()
            case .saveAndDevelop:
                coordinator?.parent.onCmdEnter?()
            case .ask:
                coordinator?.parent.onOptionEnter?()
            case .insertNewline:
                insertNewline(nil)
            }
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
