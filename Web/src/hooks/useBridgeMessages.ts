import { useState, useEffect, useRef } from 'react';
import { SourceReference, Modifier, Cell, bridge } from '../types';
import { markdownToHtml } from '../utils/markdown';
import { useBlockStore } from '../store/blockStore';
import { useToastStore } from '../store/toastStore';
import { debugError, debugLog, debugWarn } from '../utils/debug';

/**
 * EditorAPI - allows useBridgeMessages to update the TipTap document
 * when AI completes or content needs to be inserted.
 */
export interface EditorAPI {
  /** Replace the HTML content of a cell in the TipTap document */
  replaceCellHtml: (cellId: string, html: string) => void;
  /** Insert new cells into the TipTap document (for Quick Panel) */
  insertCells?: (cells: Cell[]) => void;
  /** Insert an image at the current cursor position */
  insertImage?: (imageUrl: string) => void;
}

interface UseBridgeMessagesOptions {
  streamId: string;
  initialSources: SourceReference[];
  /** Optional EditorAPI for updating TipTap content directly */
  editorAPI?: EditorAPI | null;
}

/**
 * Orchestrator hook that composes all bridge message handlers
 * Each sub-hook handles a specific domain of messages
 */
export function useBridgeMessages({ streamId, initialSources, editorAPI }: UseBridgeMessagesOptions) {
  const [sources, setSources] = useState<SourceReference[]>(initialSources);

  // Keep editorAPI in a ref so the effect doesn't re-run when it changes
  const editorAPIRef = useRef<EditorAPI | null>(null);
  editorAPIRef.current = editorAPI ?? null;

  // Update sources when initialSources changes (stream switch)
  useEffect(() => {
    setSources(initialSources);
  }, [initialSources]);

  useEffect(() => {
    debugLog('[useBridgeMessages] Setting up message handler for streamId', { streamId });

    const unsubscribe = bridge.onMessage((message) => {
      try {
      // Debug: log all messages to see what's coming through
      debugLog('[useBridgeMessages] Received', message.type);

      // IMPORTANT: Don't subscribe to the zustand store from this hook.
      // The editor updates store on keystrokes; subscribing here would cause this effect
      // to re-run and re-subscribe to the bridge constantly.
      const store = useBlockStore.getState();
      const toastStore = useToastStore.getState();

      // Normalize unknown error payloads into a user-facing string.
      const formatError = (value: unknown, fallback: string) =>
        typeof value === 'string' && value.trim().length > 0 ? value : fallback;

      // Source updates
      if (message.type === 'sourceAdded' && message.payload?.source) {
        const source = message.payload.source as SourceReference;
        if (source.streamId === streamId) {
          setSources(prev => [...prev, source]);
        }
      }
      if (message.type === 'sourceRemoved' && message.payload?.id) {
        setSources(prev => prev.filter(s => s.id !== message.payload?.id));
      }

      // Quick Panel: cells added via global hotkey capture
      if (message.type === 'quickPanelCellsAdded' && message.payload?.cells) {
        const addedStreamId = message.payload.streamId as string;
        const cells = message.payload.cells as Cell[];
        const triggerAI = message.payload.triggerAI as string | undefined;

        debugLog('[QuickPanel] Cells added', {
          streamId: addedStreamId,
          cellCount: cells.length,
          hasTriggerAI: Boolean(triggerAI),
        });

        // Only process if this is for the current stream
        if (addedStreamId === streamId) {
          // If editor API is available, insert via editor so doc + store stay aligned.
          if (editorAPIRef.current?.insertCells) {
            debugLog('[QuickPanel] Using insertCells via editor API');
            editorAPIRef.current.insertCells(cells);
          } else {
            // Store mode: add each cell directly to the store.
            for (const cell of cells) {
              store.addBlock({
                id: cell.id,
                streamId: cell.streamId,
                content: cell.content,
                type: cell.type,
                order: cell.order,
                sourceBinding: cell.sourceBinding || null,
                originalPrompt: cell.originalPrompt,
                references: cell.references,
                sourceApp: cell.sourceApp,
                createdAt: cell.createdAt || new Date().toISOString(),
                updatedAt: cell.updatedAt || new Date().toISOString(),
              });
            }
          }

          // If triggerAI is set, start AI streaming for that cell
          if (triggerAI) {
            const aiCell = cells.find(c => c.id === triggerAI);
            if (aiCell) {
              debugLog('[QuickPanel] Triggering AI', { cellId: triggerAI });
              store.startStreaming(triggerAI);

              // Get prior cells for context (exclude the AI cell itself)
              const priorCells = store.blockOrder
                .map(id => store.getBlock(id))
                .filter((b): b is NonNullable<typeof b> => b !== undefined && b.id !== triggerAI)
                .map(b => ({
                  content: b.content,
                  type: b.type,
                }));

              // Get referenced content (e.g., the quote cell from Quick Panel)
              // This is the highlighted text/screenshot that the user is asking about
              let referencedContent: string | undefined;
              let referencedImageURLs: string[] = [];
              if (aiCell.references && aiCell.references.length > 0) {
                const refCell = cells.find(c => c.id === aiCell.references?.[0]);
                if (refCell) {
                  referencedContent = refCell.content;
                  // Extract image URLs from referenced content
                  const imgMatches = refCell.content.matchAll(/<img[^>]+src="([^"]+)"/g);
                  for (const match of imgMatches) {
                    if (match[1]) {
                      referencedImageURLs.push(match[1]);
                    }
                  }
                }
              }

              // Send think request to Swift
              bridge.send({
                type: 'think',
                payload: {
                  cellId: triggerAI,
                  currentCell: aiCell.originalPrompt || '',
                  referencedContent,  // The quote/screenshot the user selected
                  referencedImageURLs, // Image URLs from the referenced cell
                  priorCells,
                  streamId,
                },
              });
            }
          }
        }
      }

      // Native file-drop errors (Swift-side)
      if (message.type === 'fileDropError' && message.payload?.error) {
        toastStore.addToast(formatError(message.payload.error, 'File import failed.'), 'error');
      }

      // Image dropped via native drag-and-drop
      if (message.type === 'imageDropped') {
        debugLog('[useBridgeMessages] imageDropped', { hasAssetUrl: Boolean(message.payload?.assetUrl) });

        const droppedStreamId = message.payload?.streamId as string | undefined;
        if (droppedStreamId && droppedStreamId !== streamId) {
          // A drop intended for a different stream; ignore.
          return;
        }

        if (message.payload?.assetUrl) {
          const assetUrl = message.payload.assetUrl as string;
          if (!assetUrl.startsWith('ticker-asset://')) {
            toastStore.addToast('Blocked unsafe image URL from native drop.', 'warning');
            return;
          }

          // If editor API is available, insert via TipTap (update handlers sync + persist).
          if (editorAPIRef.current?.insertImage) {
            debugLog('[useBridgeMessages] Using insertImage via editor API');
            editorAPIRef.current.insertImage(assetUrl);
          } else {
            // Store mode: update store directly and persist.
            const { focusedBlockId, blockOrder } = store;
            debugLog('[useBridgeMessages] Store mode inserting image', { hasFocusedBlockId: Boolean(focusedBlockId) });
            if (blockOrder.length === 0) {
              toastStore.addToast('Create a note cell first, then drop the image again.', 'info');
              return;
            }

            store.insertImageInFocusedBlock(assetUrl);

            // Save the updated block to persist the image reference
            // insertImageInFocusedBlock uses focusedBlockId or falls back to last block
            const targetBlockId = focusedBlockId || blockOrder[blockOrder.length - 1];
            const block = store.getBlock(targetBlockId);
            if (block) {
              bridge.send({
                type: 'saveCell',
                payload: {
                  id: block.id,
                  streamId,
                  content: block.content,
                  type: block.type,
                  order: block.order,
                  originalPrompt: block.originalPrompt,
                  modelId: block.modelId,
                  processingConfig: block.processingConfig,
                  modifiers: block.modifiers,
                  sourceApp: block.sourceApp,
                  references: block.references,
                  blockName: block.blockName,
                  sourceBinding: block.sourceBinding,
                },
              });
            }
          }
        } else {
          debugWarn('[useBridgeMessages] imageDropped but no assetUrl in payload');
        }
      }

      // AI streaming updates
      if (message.type === 'aiChunk' && message.payload?.cellId && message.payload?.chunk) {
        const cellId = message.payload.cellId as string;
        const chunk = message.payload.chunk as string;
        store.appendStreamingContent(cellId, chunk);
      }

      if (message.type === 'aiComplete' && message.payload?.cellId) {
        const cellId = message.payload.cellId as string;
        const rawContent = store.getStreamingContent(cellId) || '';
        const preservedImages = store.getPreservedImages(cellId) || '';
        const htmlContent = markdownToHtml(rawContent);

        // Combine preserved images with AI response
        const finalContent = preservedImages + htmlContent;

        // Update cell with final content
        const cell = store.getBlock(cellId);
        if (cell) {
          store.updateBlock(cellId, { content: finalContent });

          // Update TipTap document if an editor API is available.
          if (editorAPIRef.current) {
            debugLog('[useBridgeMessages] aiComplete: updating TipTap document', { cellId });
            editorAPIRef.current.replaceCellHtml(cellId, finalContent);
          }

          // Save to Swift (include modelId if set, preserve all metadata)
          bridge.send({
            type: 'saveCell',
            payload: {
              id: cellId,
              streamId,
              content: finalContent,
              type: 'aiResponse',
              order: cell.order,
              originalPrompt: cell.originalPrompt,
              modelId: cell.modelId,
              processingConfig: cell.processingConfig,
              sourceApp: cell.sourceApp,
              references: cell.references,
              blockName: cell.blockName,
              modifiers: cell.modifiers,
              sourceBinding: cell.sourceBinding,
            },
          });
        }

        store.completeStreaming(cellId);
      }

      if (message.type === 'aiError' && message.payload?.cellId) {
        const cellId = message.payload.cellId as string;
        const baseError = formatError(message.payload.error, 'AI request failed.');
        const errorCode = message.payload.errorCode as string | undefined;
        const requestId = message.payload.requestId as string | undefined;

        // Build enhanced error message based on error type
        let displayError = baseError;

        if (errorCode === 'quota_exceeded') {
          const scope = message.payload.quotaScope as string;
          const resetAt = message.payload.quotaResetAt as string;
          if (resetAt) {
            try {
              const resetDate = new Date(resetAt);
              const now = new Date();
              const hoursUntil = Math.ceil((resetDate.getTime() - now.getTime()) / (1000 * 60 * 60));
              displayError = `${scope === 'day' ? 'Daily' : 'Monthly'} quota exceeded. Resets in ~${hoursUntil}h.`;
            } catch {
              displayError = baseError;
            }
          }
        } else if (errorCode === 'rate_limited') {
          const retryAfter = message.payload.retryAfter as number | undefined;
          if (retryAfter) {
            displayError = `Rate limit exceeded. Try again in ${retryAfter}s.`;
          }
        } else if (errorCode === 'invalid_key' || errorCode === 'key_bound_elsewhere') {
          displayError = `${baseError} Check Settings to update your device key.`;
        } else if (errorCode === 'server_error' || errorCode === 'upstream_error') {
          if (requestId) {
            displayError = `${baseError} (Request ID: ${requestId})`;
          }
        }

        toastStore.addToast(displayError, 'error');
        store.setError(cellId, displayError);
        store.completeStreaming(cellId);
      }

      // Model selection (sent before streaming starts)
      if (message.type === 'modelSelected' && message.payload?.cellId && message.payload?.modelId) {
        const cellId = message.payload.cellId as string;
        const modelId = message.payload.modelId as string;
        store.updateBlock(cellId, { modelId });
      }

      // Modifier streaming updates
      if (message.type === 'modifierCreated' && message.payload?.cellId && message.payload?.modifier) {
        const cellId = message.payload.cellId as string;
        const modifier = message.payload.modifier as Modifier;
        debugLog('[Modifier] Created', { cellId, modifierId: modifier.id });

        // Add the modifier to the cell
        const cell = store.getBlock(cellId);
        if (cell) {
          const existingModifiers = cell.modifiers || [];
          store.updateBlock(cellId, { modifiers: [...existingModifiers, modifier] });
        }

        // Update the tracking entry with the modifier ID
        store.setModifierId(cellId, modifier.id);
      }

      if (message.type === 'modifierChunk' && message.payload?.cellId && message.payload?.chunk) {
        const cellId = message.payload.cellId as string;
        const chunk = message.payload.chunk as string;
        debugLog('[Modifier] Chunk', { cellId, chunkLength: chunk.length });
        store.appendModifyingContent(cellId, chunk);
      }

      if (message.type === 'modifierComplete' && message.payload?.cellId && message.payload?.modifierId) {
        const cellId = message.payload.cellId as string;
        const modifierId = message.payload.modifierId as string;
        debugLog('[Modifier] Complete', { cellId, modifierId });

        const modifyingData = store.getModifyingData(cellId);
        if (!modifyingData) {
          debugWarn('[Modifier] Complete but no modifying data found', { cellId });
          return;
        }

        const rawContent = modifyingData.content;
        const htmlContent = markdownToHtml(rawContent);

        const cell = store.getBlock(cellId);
        if (!cell) {
          store.completeModifying(cellId);
          return;
        }

        // Update block
        store.updateBlock(cellId, {
          content: htmlContent,
        });

        // Update TipTap document if an editor API is available.
        if (editorAPIRef.current) {
          debugLog('[useBridgeMessages] modifierComplete: updating TipTap document', { cellId });
          editorAPIRef.current.replaceCellHtml(cellId, htmlContent);
        }

        // Save to Swift (preserve all metadata)
        bridge.send({
          type: 'saveCell',
          payload: {
            id: cellId,
            streamId,
            content: htmlContent,
            type: cell.type,
            order: cell.order,
            originalPrompt: cell.originalPrompt,
            modelId: cell.modelId,
            processingConfig: cell.processingConfig,
            modifiers: cell.modifiers,
            sourceApp: cell.sourceApp,
            references: cell.references,
            blockName: cell.blockName,
            sourceBinding: cell.sourceBinding,
          },
        });

        store.completeModifying(cellId);
      }

      if (message.type === 'modifierError' && message.payload?.cellId) {
        const cellId = message.payload.cellId as string;
        const baseError = formatError(message.payload.error, 'Modifier request failed.');
        const errorCode = message.payload.errorCode as string | undefined;
        const requestId = message.payload.requestId as string | undefined;

        let displayError = `Modifier failed: ${baseError}`;
        if (requestId && (errorCode === 'server_error' || errorCode === 'upstream_error')) {
          displayError = `${displayError} (Request ID: ${requestId})`;
        }

        toastStore.addToast(displayError, 'error');
        store.setError(cellId, displayError);
        store.completeModifying(cellId);
      }

      // Block refresh updates (live blocks, cascade updates)
      if (message.type === 'blockRefreshStart' && message.payload?.cellId) {
        const cellId = message.payload.cellId as string;
        debugLog('[BlockRefresh] Start', { cellId });
        store.startRefreshing(cellId);
      }

      if (message.type === 'blockRefreshChunk' && message.payload?.cellId && message.payload?.chunk) {
        const cellId = message.payload.cellId as string;
        const chunk = message.payload.chunk as string;
        store.appendRefreshingContent(cellId, chunk);
      }

      if (message.type === 'blockRefreshComplete' && message.payload?.cellId && message.payload?.content) {
        const cellId = message.payload.cellId as string;
        const rawContent = message.payload.content as string;
        const htmlContent = markdownToHtml(rawContent);
        debugLog('[BlockRefresh] Complete', { cellId });

        const cell = store.getBlock(cellId);
        if (cell) {
          store.updateBlock(cellId, { content: htmlContent });

          // Update TipTap document if an editor API is available.
          if (editorAPIRef.current) {
            debugLog('[useBridgeMessages] blockRefreshComplete: updating TipTap document', { cellId });
            editorAPIRef.current.replaceCellHtml(cellId, htmlContent);
          }

          // Save refreshed content to Swift (preserve all metadata)
          bridge.send({
            type: 'saveCell',
            payload: {
              id: cellId,
              streamId,
              content: htmlContent,
              type: cell.type,
              order: cell.order,
              originalPrompt: cell.originalPrompt,
              modelId: cell.modelId,
              processingConfig: cell.processingConfig,
              references: cell.references,
              blockName: cell.blockName,
              sourceApp: cell.sourceApp,
            },
          });
        }

        store.completeRefreshing(cellId);
      }

      if (message.type === 'blockRefreshError' && message.payload?.cellId) {
        const cellId = message.payload.cellId as string;
        const baseError = formatError(message.payload.error, 'Refresh failed.');
        const errorCode = message.payload.errorCode as string | undefined;
        const requestId = message.payload.requestId as string | undefined;

        let displayError = `Refresh failed: ${baseError}`;
        if (requestId && (errorCode === 'server_error' || errorCode === 'upstream_error')) {
          displayError = `${displayError} (Request ID: ${requestId})`;
        }

        debugError('[BlockRefresh] Error', {
          cellId,
          errorCode,
          hasRequestId: Boolean(requestId),
        });
        toastStore.addToast(displayError, 'error');
        store.setError(cellId, displayError);
        store.completeRefreshing(cellId);
      }

      // Export events
      if (message.type === 'exportComplete' && message.payload?.path) {
        const path = message.payload.path as string;
        const filename = path.split('/').pop() || 'file';
        toastStore.addToast(`Exported to ${filename}`, 'info');
      }

      if (message.type === 'exportError' && message.payload?.error) {
        const error = formatError(message.payload.error, 'Export failed.');
        toastStore.addToast(`Export failed: ${error}`, 'error');
      }

      // exportCanceled is silent (user intentionally canceled)
      } catch (err) {
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
