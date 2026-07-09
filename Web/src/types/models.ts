/** A thinking session containing a Markdown document and source references */
export interface Stream {
  id: string;
  title: string;
  sourceScope: SourceScope;
  sources: SourceReference[];
  document: StreamDocument;
  spans: ProvenanceSpanJSON[];
  marginNotes: MarginNoteJSON[];
  createdAt: string;
  updatedAt: string;
}

export type SourceScope = 'auto' | 'all' | 'none';

/** Canonical Markdown document for a stream */
export interface StreamDocument {
  streamId: string;
  markdown: string;
  revision: number;
  scrollOffset: number;
  createdAt: string;
  updatedAt: string;
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
  verb: string;
  userInput: string;
  sourceManifest: string;
  responseRaw: string;
  model?: string | null;
  createdAt: string;
}

/** Lightweight summary for list views */
export interface StreamSummary {
  id: string;
  title: string;
  sourceCount: number;
  sourceShortTitle?: string;
  cellCount: number;
  charCount: number;
  wordCount: number;
  imageCount: number;
  updatedAt: string;
  previewText: string | null;
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
  sourceType: 'cell' | 'chunk';
  title: string;
  shortTitle?: string;
  snippet: string;
  cellType?: 'text' | 'aiResponse' | 'quote';
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
