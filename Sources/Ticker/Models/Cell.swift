import Foundation

/// A single modification in the modifier chain
struct Modifier: Identifiable, Codable {
    let id: UUID
    var prompt: String      // Full prompt text ("make it shorter")
    var label: String       // AI-generated 1-3 word summary ("shorter")
    let createdAt: Date

    init(
        id: UUID = UUID(),
        prompt: String,
        label: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.prompt = prompt
        self.label = label
        self.createdAt = createdAt
    }
}

/// A version of content produced by the modifier chain
struct CellVersion: Identifiable, Codable {
    let id: UUID
    var content: String         // HTML content for this version
    var modifierIds: [UUID]     // Which modifiers produced this
    let createdAt: Date

    init(
        id: UUID = UUID(),
        content: String,
        modifierIds: [UUID],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.modifierIds = modifierIds
        self.createdAt = createdAt
    }
}

/// A unit of content within a stream
struct Cell: Identifiable, Codable {
    let id: UUID
    let streamId: UUID
    var content: String
    /// Original user prompt (for aiResponse cells that transformed from text cells)
    var originalPrompt: String?
    var type: CellType
    var sourceBinding: SourceBinding?
    var order: Int
    let createdAt: Date
    var updatedAt: Date
    /// Modifier chain - prompts that have been applied to transform content
    var modifiers: [Modifier]?
    /// Content versions - each modifier produces a new version
    var versions: [CellVersion]?
    /// Currently displayed version (if not set, show latest)
    var activeVersionId: UUID?
    /// Processing configuration for automatic behavior (@live, schema validation, etc.)
    var processingConfig: ProcessingConfig?
    /// IDs of blocks this block references (for dependency tracking)
    var references: [UUID]?
    /// Short name for @mentions (e.g., "nasdaq" for @block-nasdaq)
    var blockName: String?
    /// ID of the model that generated this response (e.g., "gpt-4o", "sonar")
    var modelId: String?
    /// Source application name (for quote cells captured via Quick Panel)
    var sourceApp: String?

    init(
        id: UUID = UUID(),
        streamId: UUID,
        content: String,
        originalPrompt: String? = nil,
        type: CellType = .text,
        sourceBinding: SourceBinding? = nil,
        order: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        modifiers: [Modifier]? = nil,
        versions: [CellVersion]? = nil,
        activeVersionId: UUID? = nil,
        processingConfig: ProcessingConfig? = nil,
        references: [UUID]? = nil,
        blockName: String? = nil,
        modelId: String? = nil,
        sourceApp: String? = nil
    ) {
        self.id = id
        self.streamId = streamId
        self.content = content
        self.originalPrompt = originalPrompt
        self.type = type
        self.sourceBinding = sourceBinding
        self.order = order
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.modifiers = modifiers
        self.versions = versions
        self.activeVersionId = activeVersionId
        self.processingConfig = processingConfig
        self.references = references
        self.blockName = blockName
        self.modelId = modelId
        self.sourceApp = sourceApp
    }
}

/// The type of cell content
enum CellType: String, Codable {
    case text        // User-written content
    case aiResponse  // AI-generated response
    case quote       // Excerpt from a source
}
