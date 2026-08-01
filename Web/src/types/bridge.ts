import { debugLog } from '../utils/debug';
import type {
  AIExchangeJSON,
  ConversationAnchorJSON,
  PendingAppendJSON,
  ProvenanceSpanJSON,
  StreamAppendInboxJSON,
  StreamThreadJSON,
} from './models';

/** Message structure for Swift ↔ JS communication */
export const SWIFT_TO_WEB_MESSAGE_TYPES = [
  'aiOperationChanged',
  'documentAIChunk',
  'documentAIComplete',
  'documentAIError',
  'documentModelSelected',
  'threadAIContext',
  'bridgeError',
  'callback',
  'fileDropError',
  'flushEditor',
  'getEditorSelection',
  'imageDropped',
  'imageSaveError',
  'imageSaved',
  'marginNotesChanged',
  'proxyAuthState',
  'pdfAnchorPickCancelled',
  'pdfAnchorPlaced',
  'pdfHighlightDeleted',
  'pdfHighlightLinked',
  'pdfThreadRequested',
  'pdfPaneStateChanged',
  'pdfSectionActionRequested',
  'revealPdfHighlightInStream',
  'settingsLoaded',
  'storageStateChanged',
  'sourceAdded',
  'sourceError',
  'sourceIndexStatusChanged',
  'sourceRemoveError',
  'sourceRemoved',
  'streamDocumentAppended',
  'streamAppendInboxChanged',
  'streamDocumentConflict',
  'streamLoaded',
  'streamLoadFailed',
  'streamTitleUpdated',
  'streamsChanged',
  'streamsLoaded',
  'streamsLoadFailed',
] as const;

export type SwiftToWebMessageType = (typeof SWIFT_TO_WEB_MESSAGE_TYPES)[number];
export type AIOperationState = 'queued' | 'preparing' | 'generating' | 'saving' | 'succeeded' | 'failed' | 'canceled';

export const WEB_TO_SWIFT_MESSAGE_TYPES = [
  'addSource',
  'beginPdfAnchorPick',
  'deletePdfHighlight',
  'cancelDocumentAI',
  'cancelAIOperation',
  'clearProxyDeviceKey',
  'createStreamThread',
  'createStream',
  'deleteStreamThread',
  'deleteStream',
  'editorFlushed',
  'editorSelection',
  'getSupportBundle',
  'hybridSearch',
  'loadProxyAuth',
  'loadSettings',
  'loadStorageState',
  'listConversations',
  'loadStreamThread',
  'loadStream',
  'loadStreams',
  'getExchange',
  'openExternalURL',
  'openPdfDestination',
  'openSource',
  'quitApp',
  'refreshProxyAuth',
  'removeSource',
  'retrySourceIndexing',
  'runPdfSectionAI',
  'saveImage',
  'saveSettings',
  'saveScrollPosition',
  'saveRichStreamDocument',
  'saveStreamDocument',
  'saveStreamThread',
  'setFileDropContext',
  'setSourceAIExclusion',
  'setSourceScope',
  'setProxyDeviceKey',
  'submitFeedback',
  'thinkDocument',
  'updateMarginNote',
  'updateStreamTitle',
] as const;

export type WebToSwiftMessageType = (typeof WEB_TO_SWIFT_MESSAGE_TYPES)[number];
export type DocumentAIVerb = 'develop' | 'ask' | 'challenge' | 'define' | 'rewrite';
export type DocumentAISourceScope = 'auto' | 'all' | 'none';

export interface ThinkDocumentPayload extends Record<string, unknown> {
  requestId: string;
  streamId: string;
  query: string;
  imageURLs: string[];
  context?: string;
  sourceScope?: DocumentAISourceScope;
  verb?: DocumentAIVerb;
  parentRequestId?: string;
  threadId?: string;
  anchorStart?: number;
  anchorEnd?: number;
  streamMarkdown?: string;
}

export interface UpdateMarginNotePayload extends Record<string, unknown> {
  noteId: string;
  status: 'open' | 'dismissed' | 'promoted' | 'unanchored';
}

export interface BridgeMessage {
  type: string;
  payload?: Record<string, unknown>;
  callbackId?: string;
}

export interface StreamDocumentConflictPayload extends Record<string, unknown> {
  streamId: string;
  docJSON?: string;
  docFormatVersion?: number;
  markdown: string;
  revision: number;
  spans: ProvenanceSpanJSON[];
  conversationAnchors: ConversationAnchorJSON[];
  pendingAppends: PendingAppendJSON[];
  appendInbox: StreamAppendInboxJSON[];
}

export type SwiftToWebBridgeMessage = Omit<BridgeMessage, 'type'> & { type: SwiftToWebMessageType };
export type WebToSwiftBridgeMessage = Omit<BridgeMessage, 'type'> & { type: WebToSwiftMessageType };

export interface DocumentAICitation {
  n: number;
  chunkId: string;
  sourceId: string;
  page: number;
  shortTitle: string;
}

export interface SourceTitlePayload {
  sourceName?: string;
  shortTitle?: string;
}

export type DocumentAISourceContextMode = 'passthrough' | 'retrieved' | 'none' | 'unavailable';

/** Callback registry for async responses */
type CallbackFn = (payload: Record<string, unknown>) => void;

/** Bridge interface for communicating with Swift */
export interface Bridge {
  send: (message: WebToSwiftBridgeMessage) => void;
  sendAsync: <T>(type: WebToSwiftMessageType, payload?: Record<string, unknown>) => Promise<T>;
  receive: (message: SwiftToWebBridgeMessage) => void;
  onMessage: (handler: (message: SwiftToWebBridgeMessage) => void) => () => void;
}

const callbacks = new Map<string, CallbackFn>();
const messageHandlers = new Set<(message: SwiftToWebBridgeMessage) => void>();

let callbackId = 0;
function nextCallbackId(): string {
  return `cb_${++callbackId}`;
}

/** Global bridge instance */
export const bridge: Bridge = {
  /** Send a message to Swift (fire and forget) */
  send(message: WebToSwiftBridgeMessage): void {
    window.webkit?.messageHandlers?.bridge?.postMessage(message);
  },

  /** Send a message and wait for response */
  sendAsync<T>(type: WebToSwiftMessageType, payload?: Record<string, unknown>): Promise<T> {
    return new Promise((resolve, reject) => {
      const id = nextCallbackId();
      const timeout = setTimeout(() => {
        callbacks.delete(id);
        reject(new Error(`Bridge timeout: ${type}`));
      }, 30000);

      callbacks.set(id, (response) => {
        clearTimeout(timeout);
        callbacks.delete(id);
        if (response.error) {
          reject(new Error(String(response.error)));
        } else {
          resolve(response as T);
        }
      });

      this.send({ type, payload, callbackId: id });
    });
  },

  /** Called by Swift to deliver messages */
  receive(message: SwiftToWebBridgeMessage): void {
    // Debug: log all incoming messages
    debugLog('[Bridge.receive]', message.type, message.payload ? Object.keys(message.payload) : 'no payload');

    // Handle callback responses
    if (message.type === 'callback' && message.callbackId) {
      const callback = callbacks.get(message.callbackId);
      if (callback && message.payload) {
        callback(message.payload);
      }
      return;
    }

    // Dispatch to message handlers
    debugLog('[Bridge.receive] Dispatching to', messageHandlers.size, 'handlers');
    messageHandlers.forEach((handler) => handler(message));
  },

  /** Subscribe to incoming messages */
  onMessage(handler: (message: SwiftToWebBridgeMessage) => void): () => void {
    messageHandlers.add(handler);
    return () => messageHandlers.delete(handler);
  },
};

export function getExchange(requestId: string): Promise<{ exchange: AIExchangeJSON | null }> {
  return bridge.sendAsync('getExchange', { requestId });
}

export function listConversations(streamId: string): Promise<{ conversations: ConversationAnchorJSON[] }> {
  return bridge.sendAsync('listConversations', { streamId });
}

export function createStreamThread(input: {
  streamId: string;
  title: string;
  anchorStart: number;
  anchorEnd: number;
  anchorText: string;
}): Promise<{ thread: StreamThreadJSON }> {
  return bridge.sendAsync('createStreamThread', {
    streamId: input.streamId,
    title: input.title,
    anchorStart: input.anchorStart,
    anchorEnd: input.anchorEnd,
    anchorText: input.anchorText,
  });
}

export function loadStreamThread(
  streamId: string,
  threadId: string,
): Promise<{ thread: StreamThreadJSON }> {
  return bridge.sendAsync('loadStreamThread', { streamId, threadId });
}

export function deleteStreamThread(input: {
  streamId: string;
  threadId: string;
}): Promise<{ highlightIds: string[] }> {
  return bridge.sendAsync('deleteStreamThread', {
    streamId: input.streamId,
    threadId: input.threadId,
  });
}

export function updateMarginNote(payload: UpdateMarginNotePayload): void {
  bridge.send({
    type: 'updateMarginNote',
    payload: {
      noteId: payload.noteId,
      status: payload.status,
    },
  });
}

export function saveStreamThread(input: {
  streamId: string;
  threadId: string;
  title: string;
  baseRevision: number;
}): Promise<{ conflict: boolean; thread: StreamThreadJSON }> {
  return bridge.sendAsync('saveStreamThread', {
    streamId: input.streamId,
    threadId: input.threadId,
    title: input.title,
    baseRevision: input.baseRevision,
  });
}

// Expose bridge globally for Swift to call
declare global {
  interface Window {
    bridge?: Bridge;
    webkit?: {
      messageHandlers?: {
        bridge?: {
          postMessage: (message: BridgeMessage) => void;
        };
      };
    };
  }
}

if (typeof window !== 'undefined') {
  window.bridge = bridge;
  debugLog('[Bridge] window.bridge initialized');
}
