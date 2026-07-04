/** A thinking session containing a Markdown document and source references */
export interface Stream {
  id: string;
  title: string;
  sources: SourceReference[];
  document: StreamDocument;
  createdAt: string;
  updatedAt: string;
}

/** Canonical Markdown document for a stream */
export interface StreamDocument {
  streamId: string;
  markdown: string;
  revision: number;
  createdAt: string;
  updatedAt: string;
}

/** Lightweight summary for list views */
export interface StreamSummary {
  id: string;
  title: string;
  sourceCount: number;
  cellCount: number;
  charCount: number;
  imageCount: number;
  updatedAt: string;
  previewText: string | null;
}

/** A reference to an external file */
export interface SourceReference {
  id: string;
  streamId: string;
  displayName: string;
  fileType: SourceFileType;
  status: SourceStatus;
  embeddingStatus: SourceEmbeddingStatus;
  indexStatus: SourceIndexStatus;
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
