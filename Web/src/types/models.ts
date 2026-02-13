/** A thinking session containing cells and source references */
export interface Stream {
  id: string;
  title: string;
  sources: SourceReference[];
  cells: Cell[];
  document: StreamDocument;
  createdAt: string;
  updatedAt: string;
}

/** Canonical Markdown document for a stream */
export interface StreamDocument {
  streamId: string;
  markdown: string;
  createdAt: string;
  updatedAt: string;
}

/** Lightweight summary for list views */
export interface StreamSummary {
  id: string;
  title: string;
  sourceCount: number;
  cellCount: number;
  updatedAt: string;
  previewText: string | null;
}

/** A unit of content within a stream */
export interface Cell {
  id: string;
  streamId: string;
  content: string;
  /** Original user prompt (for aiResponse cells that transformed from text cells) */
  originalPrompt?: string;
  type: CellType;
  sourceBinding: SourceBinding | null;
  order: number;
  createdAt: string;
  updatedAt: string;
  /** Modifier chain - prompts that have been applied to transform content */
  modifiers?: Modifier[];
  /** Processing configuration for automatic behavior (@live, schema validation, etc.) */
  processingConfig?: ProcessingConfig;
  /** IDs of blocks this block references (for dependency tracking) */
  references?: string[];
  /** Short name for @mentions (e.g., "nasdaq" for @block-nasdaq) */
  blockName?: string;
  /** ID of the model that generated this response (e.g., "gpt-4o", "sonar") */
  modelId?: string;
  /** Source application name (for quote cells captured via Quick Panel) */
  sourceApp?: string;
}

/** The type of cell content */
export type CellType = 'text' | 'aiResponse' | 'quote';

/** A single modification in the modifier chain */
export interface Modifier {
  id: string;
  prompt: string;      // Full prompt text ("make it shorter")
  label: string;       // AI-generated 1-3 word summary ("shorter")
  createdAt: string;
}

/** A reference to an external file */
export interface SourceReference {
  id: string;
  streamId: string;
  displayName: string;
  fileType: SourceFileType;
  status: SourceStatus;
  embeddingStatus: SourceEmbeddingStatus;
  extractedText: string | null;
  pageCount: number | null;
  addedAt: string;
}

/** Supported source file types */
export type SourceFileType = 'pdf' | 'text' | 'markdown' | 'image';

/** Status of a source reference */
export type SourceStatus = 'pending' | 'ready' | 'stale' | 'error';

/** Status of RAG embedding for a source */
export type SourceEmbeddingStatus = 'none' | 'processing' | 'complete' | 'failed';

/** Links a cell to a specific location in a source file */
export interface SourceBinding {
  sourceId: string;
  location: SourceLocation;
}

/** Location within a source file */
export type SourceLocation =
  | { type: 'whole' }
  | { type: 'page'; page: number }
  | { type: 'pageRange'; startPage: number; endPage: number };

/** Configuration for automatic block processing behavior */
export interface ProcessingConfig {
  /** When this block should refresh its content */
  refreshTrigger?: RefreshTrigger;
  /** Schema for validating AI responses */
  schema?: BlockSchema;
  /** Rule for automatic content transformation */
  autoTransform?: AutoTransformRule;
}

/** Triggers for automatic block refresh */
export type RefreshTrigger = 'onStreamOpen' | 'onDependencyChange' | 'manual';

/** Schema for validating and constraining AI responses */
export interface BlockSchema {
  /** JSON Schema string for validation */
  jsonSchema: string;
  /** When the block was last validated against the schema */
  lastValidatedAt?: string;
  /** Whether the current content has drifted from the schema */
  driftDetected?: boolean;
}

/** Rule for automatic content transformation */
export interface AutoTransformRule {
  /** Condition that triggers the transformation (e.g., "contentLength > 500") */
  condition: string;
  /** The transformation to apply (e.g., "summarize") */
  transformation: string;
}

// MARK: - Search Types

/** Result from hybrid search */
export interface SearchResult {
  id: string;
  streamId: string;
  streamTitle: string;
  sourceType: 'cell' | 'chunk';
  title: string;
  snippet: string;
  cellType?: CellType;
  /** Source ID for chunk results (to navigate to source panel) */
  sourceId?: string;
  sourceName?: string;
  similarity?: number;
  matchType: 'text' | 'semantic' | 'both';
}

/** Response from hybrid search API */
export interface HybridSearchResults {
  currentStreamResults: SearchResult[];
  otherStreamResults: SearchResult[];
}
