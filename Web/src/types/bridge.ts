import { debugLog } from '../utils/debug';

/** Message structure for Swift ↔ JS communication */
export const SWIFT_TO_WEB_MESSAGE_TYPES = [
  'documentAIChunk',
  'documentAIComplete',
  'documentAIError',
  'documentModelSelected',
  'assetPath',
  'callback',
  'exportCanceled',
  'exportComplete',
  'exportError',
  'fileDropError',
  'imageDropped',
  'imageSaveError',
  'imageSaved',
  'proxyAuthState',
  'pdfHighlightLinked',
  'settingsLoaded',
  'sourceAdded',
  'sourceError',
  'sourceRemoveError',
  'sourceRemoved',
  'streamDocumentAppended',
  'streamLoaded',
  'streamTitleUpdated',
  'streamsChanged',
  'streamsLoaded',
] as const;

export type SwiftToWebMessageType = (typeof SWIFT_TO_WEB_MESSAGE_TYPES)[number];

export interface BridgeMessage {
  type: string;
  payload?: Record<string, unknown>;
  callbackId?: string;
}

export type SwiftToWebBridgeMessage = Omit<BridgeMessage, 'type'> & { type: SwiftToWebMessageType };

/** Callback registry for async responses */
type CallbackFn = (payload: Record<string, unknown>) => void;

/** Bridge interface for communicating with Swift */
export interface Bridge {
  send: (message: BridgeMessage) => void;
  sendAsync: <T>(type: string, payload?: Record<string, unknown>) => Promise<T>;
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
  send(message: BridgeMessage): void {
    window.webkit?.messageHandlers?.bridge?.postMessage(message);
  },

  /** Send a message and wait for response */
  sendAsync<T>(type: string, payload?: Record<string, unknown>): Promise<T> {
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

window.bridge = bridge;
debugLog('[Bridge] window.bridge initialized');
