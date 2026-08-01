/** A thinking session containing a document and source references. */
export interface Stream {
  id: string;
  title: string;
  sourceScope: SourceScope;
  sources: SourceReference[];
  document: StreamDocument;
  spans: ProvenanceSpanJSON[];
  conversationAnchors?: ConversationAnchorJSON[];
  pendingAppends?: PendingAppendJSON[];
  appendInbox?: StreamAppendInboxJSON[];
  marginNotes: MarginNoteJSON[];
  createdAt: string;
  updatedAt: string;
}

export type SourceScope = 'auto' | 'all' | 'none';

/** The document plus its derived Markdown projection. */
export interface StreamDocument {
  streamId: string;
  docJSON?: string;
  docFormatVersion?: number;
  markdown: string;
  revision: number;
  scrollOffset: number;
  createdAt: string;
  updatedAt: string;
}

/**
 * An append made while no editor was open. Its provenance is still in fragment
 * coordinates — only an editor can turn those into document positions — so it
 * travels with the document and is cleared by the save that follows.
 */
export interface PendingAppendJSON {
  revision: number;
  separator: string;
  fragment: string;
  rawSpansJSON: string;
}

/** A durable Markdown append waiting for the rich editor to reduce it. */
export interface StreamAppendInboxJSON {
  seq: number;
  appendId: string;
  fragment: string;
  rawSpansJSON: string;
  createdAt: string;
}

export interface ProvenanceSpanJSON {
  spanId: string;
  start: number;
  end: number;
  origin: string;
  requestId?: string;
  sourceId?: string;
  meta: string;
  textHash: string;
  createdAt: string;
}

export interface ConversationAnchorJSON {
  threadId: string;
  anchorStart: number | null;
  anchorEnd: number | null;
  anchorText: string;
  detached: boolean;
  ephemeral: boolean;
  updatedAt: string;
}

export interface MarginNoteJSON {
  noteId: string;
  streamId: string;
  anchorStart: number;
  anchorEnd: number;
  anchorHash: string;
  kind: 'question' | 'tension' | 'connection';
  body: string;
  bodyHash: string;
  requestId?: string;
  status: 'open' | 'dismissed' | 'promoted' | 'unanchored';
  createdAt: string;
}

export interface AIExchangeJSON {
  requestId: string;
  streamId: string;
  threadId?: string;
  verb: string;
  userInput: string;
  sourceManifest: string;
  responseRaw: string;
  model?: string | null;
  threadDisposition?: 'pending' | 'kept' | 'discarded' | null;
  createdAt: string;
}

export interface StreamThreadAnchorJSON {
  anchorId: string;
  threadId: string;
  kind: 'stream_quote' | 'pdf_quote';
  quote?: string;
  anchorSpanId?: string;
  anchorStart?: number;
  anchorEnd?: number;
  sourceId?: string;
  sourceName?: string;
  sourceShortTitle?: string;
  highlightId?: string;
  sourcePage?: number;
  createdAt: string;
}

export interface ProvisionalPDFHighlightJSON {
  highlightId: string;
  sourceId: string;
  page: number;
  quote: string;
  createdAt: string;
  rects: Array<{ page: number; x: number; y: number; w: number; h: number }>;
}

export interface StreamThreadJSON {
  threadId: string;
  streamId: string;
  title: string;
  workingText: string;
  docJSON?: string;
  docFormatVersion?: number;
  anchorText: string;
  anchorSpanId?: string;
  sourceId?: string;
  sourceName?: string;
  sourceShortTitle?: string;
  highlightId?: string;
  sourcePage?: number;
  anchorStart?: number;
  anchorEnd?: number;
  detached?: boolean;
  ephemeral?: boolean;
  revision: number;
  createdAt: string;
  updatedAt: string;
  anchors?: StreamThreadAnchorJSON[];
  exchanges?: AIExchangeJSON[];
}

/** Lightweight summary for list views */
export interface StreamSummary {
  id: string;
  title: string;
  sourceCount: number;
  sourceShortTitle?: string;
  charCount: number;
  wordCount: number;
  imageCount: number;
  openQuestionCount: number;
  updatedAt: string;
  previewLine: string | null;
}

/** A reference to an external file */
export interface SourceReference {
  id: string;
  streamId: string;
  displayName: string;
  shortTitle: string;
  fileType: SourceFileType;
  status: SourceStatus;
  embeddingStatus: SourceEmbeddingStatus;
  indexStatus: SourceIndexStatus;
  aiExcluded: boolean;
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

/** Status of local source chunk indexing */
export type SourceIndexStatus = 'pending' | 'indexing' | 'ready' | 'failed_no_text' | 'failed';

// MARK: - Search Types

/** Result from hybrid search */
export interface SearchResult {
  id: string;
  streamId: string;
  streamTitle: string;
  sourceType: 'document' | 'chunk';
  title: string;
  shortTitle?: string;
  snippet: string;
  /** Source ID for chunk results (to navigate to source panel) */
  sourceId?: string;
  sourceName?: string;
}

/** Response from hybrid search API */
export interface HybridSearchResults {
  currentStreamResults: SearchResult[];
  otherStreamResults: SearchResult[];
}
