import { useState, useEffect, useRef } from 'react';
import type { SourceIndexStatus, SourceReference } from '../types';
import { bridge } from '../types';
import { useToastStore } from '../store/toastStore';
import { debugError, debugLog, debugWarn } from '../utils/debug';

export interface EditorAPI {
  insertImage: (imageUrl: string) => void;
}

interface UseBridgeMessagesOptions {
  streamId: string;
  initialSources: SourceReference[];
  editorAPI?: EditorAPI | null;
}

function isSourceIndexStatus(value: unknown): value is SourceIndexStatus {
  return value === 'pending'
    || value === 'indexing'
    || value === 'ready'
    || value === 'failed_no_text'
    || value === 'failed';
}

export function useBridgeMessages({ streamId, initialSources, editorAPI }: UseBridgeMessagesOptions) {
  const [sources, setSources] = useState<SourceReference[]>(initialSources);
  const editorAPIRef = useRef<EditorAPI | null>(null);
  editorAPIRef.current = editorAPI ?? null;

  useEffect(() => {
    setSources(initialSources);
  }, [initialSources]);

  useEffect(() => {
    debugLog('[useBridgeMessages] Setting up message handler for streamId', { streamId });

    const unsubscribe = bridge.onMessage((message) => {
      try {
        debugLog('[useBridgeMessages] Received', message.type);

        const toastStore = useToastStore.getState();
        const formatError = (value: unknown, fallback: string) =>
          typeof value === 'string' && value.trim().length > 0 ? value : fallback;

        if (message.type === 'sourceAdded' && message.payload?.source) {
          const source = message.payload.source as SourceReference;
          if (source.streamId === streamId) {
            setSources((prev) => [...prev, source]);
          }
        }

        if (message.type === 'sourceRemoved' && message.payload?.id) {
          const removedId = message.payload.id as string;
          setSources((prev) => prev.filter((source) => source.id !== removedId));
        }

        if (message.type === 'sourceIndexStatusChanged' && message.payload?.sourceId) {
          const sourceId = message.payload.sourceId as string;
          const status = message.payload.status;
          if (isSourceIndexStatus(status)) {
            setSources((prev) => prev.map((source) => (
              source.id === sourceId ? { ...source, indexStatus: status } : source
            )));
          }
        }

        if (message.type === 'sourceError' && message.payload?.error) {
          toastStore.addToast(formatError(message.payload.error, 'Source update failed.'), 'error');
        }

        if (message.type === 'sourceRemoveError' && message.payload?.error) {
          toastStore.addToast(formatError(message.payload.error, 'Source removal failed.'), 'error');
        }

        if (message.type === 'fileDropError' && message.payload?.error) {
          toastStore.addToast(formatError(message.payload.error, 'File import failed.'), 'error');
        }

        if (message.type === 'imageDropped') {
          debugLog('[useBridgeMessages] imageDropped', { hasAssetUrl: Boolean(message.payload?.assetUrl) });

          const droppedStreamId = message.payload?.streamId as string | undefined;
          if (droppedStreamId && droppedStreamId !== streamId) {
            return;
          }

          const assetUrl = message.payload?.assetUrl as string | undefined;
          if (!assetUrl) {
            debugWarn('[useBridgeMessages] imageDropped but no assetUrl in payload');
            return;
          }

          if (!assetUrl.startsWith('ticker-asset://')) {
            toastStore.addToast('Blocked unsafe image URL from native drop.', 'warning');
            return;
          }

          if (!editorAPIRef.current) {
            toastStore.addToast('Open a stream before dropping the image again.', 'info');
            return;
          }

          editorAPIRef.current.insertImage(assetUrl);
        }
      } catch {
        debugError('[useBridgeMessages] Error handling message', { type: message.type });
      }
    });

    return () => {
      debugLog('[useBridgeMessages] Cleaning up message handler for streamId', { streamId });
      unsubscribe();
    };
  }, [streamId]);

  return {
    sources,
    setSources,
  };
}
