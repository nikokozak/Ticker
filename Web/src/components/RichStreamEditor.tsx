import { useCallback, useEffect, useRef, useState } from 'react';
import type { Slice } from 'prosemirror-model';
import type { Command } from 'prosemirror-state';
import {
  bridge,
  type DocumentAIVerb,
  type StreamDocumentConflictPayload,
} from '../types/bridge';
import type { Stream } from '../types/models';
import { Modal } from './Modal';
import { createRichTextEditor, type RichTextEditor } from '../richtext/editor';
import {
  aiWritingRange,
  insertImage,
  selectText,
  setAIWritingRange,
  streamAIMarkdown,
} from '../richtext/operations';
import { DocumentSession, type SaveState } from '../richtext/session';
import {
  addProvenanceSpans,
  hashProvenanceText,
  spanFromJSON,
  type ProvenanceSpanJSON,
} from '../richtext/provenance';
import { parseRawSpans, type PendingAppend } from '../richtext/pendingAppends';
import { useToastStore } from '../store/toastStore';
import {
  buildProvenanceLine,
  parseDocumentAICitations,
  swapCitationMarkersWithMetadata,
} from '../utils/citationMarkers';
import {
  activeFormats,
  toggleBlockquote,
  toggleBold,
  toggleBulletList,
  toggleCode,
  toggleHeading,
  toggleItalic,
  toggleOrderedList,
  toggleUnderline,
} from '../richtext/commands';
import '../richtext/editor.css';

/**
 * The editor page, on the ProseMirror editor.
 *
 * The component is deliberately thin. Everything that can be wrong in a way that
 * loses a user's writing — the codec, save/append/conflict, provenance — lives in
 * `src/richtext/` with its own tests. What is left here is wiring: the bridge on
 * one side, the chrome on the other.
 */

interface RichStreamEditorProps {
  stream: Stream;
  onBack: () => void;
  onDelete: () => void;
  pendingMatchText?: string | null;
  onClearPendingMatch?: () => void;
}

const PDF_URL_PREFIX = 'ticker-pdf://';

function readBlobAsBase64(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const data = String(reader.result).split(',')[1];
      if (data) resolve(data);
      else reject(new Error('Invalid image encoding.'));
    };
    reader.onerror = () => reject(new Error('Failed to read image data.'));
    reader.readAsDataURL(blob);
  });
}

interface ActiveDocumentAI {
  requestId: string;
  editor: RichTextEditor;
  original: Slice;
  stream: ReturnType<typeof streamAIMarkdown>;
  verb: Exclude<DocumentAIVerb, 'challenge'>;
  model?: string;
}

function documentAITarget(editor: RichTextEditor): { from: number; to: number; text: string } | null {
  const { doc, selection } = editor.view.state;
  const from = selection.empty ? selection.$head.start() : selection.from;
  const to = selection.empty ? selection.$head.end() : selection.to;
  const text = doc.textBetween(from, to, '\n', '').trim();
  return text ? { from, to, text } : null;
}

function restoreDocumentAI(editor: RichTextEditor, active: ActiveDocumentAI): void {
  const { view } = editor;
  const written = active.stream.done();
  const range = aiWritingRange(view.state) ?? written;
  const tr = view.state.tr.replaceRange(range.from, range.to, active.original);
  setAIWritingRange(tr, null).setMeta('addToHistory', false);
  view.dispatch(tr);
}

/** The store's rows, in the shape the session proves things about. */
const decodePendingAppends = (rows: Stream['pendingAppends']): PendingAppend[] => (rows ?? []).map((append) => ({
  revision: append.revision,
  separator: append.separator,
  fragment: append.fragment,
  rawSpans: parseRawSpans(append.rawSpansJSON),
}));

const SAVE_LABEL: Record<SaveState, string> = {
  saved: 'Saved',
  saving: 'Saving…',
  error: 'Save failed',
};

export function RichStreamEditor({
  stream,
  onBack,
  onDelete,
  pendingMatchText,
  onClearPendingMatch,
}: RichStreamEditorProps) {
  const host = useRef<HTMLDivElement>(null);
  const editorRef = useRef<RichTextEditor | null>(null);
  const sessionRef = useRef<DocumentSession | null>(null);
  const aiRequestRef = useRef<ActiveDocumentAI | null>(null);
  const aiInFlightRef = useRef(false);

  const [editor, setEditor] = useState<RichTextEditor | null>(null);
  const [saveState, setSaveState] = useState<SaveState>('saved');
  const [aiRunning, setAIRunning] = useState(false);
  const [aiDetail, setAIDetail] = useState<string | null>(null);
  const [promptVerb, setPromptVerb] = useState<'ask' | 'rewrite' | null>(null);
  const [promptValue, setPromptValue] = useState('');
  const [leaving, setLeaving] = useState(false);
  const deleting = useRef(false);
  const [xray, setXray] = useState(false);
  const [title, setTitle] = useState(stream.title);
  const [, redraw] = useState(0);
  const addToast = useToastStore((state) => state.addToast);

  const cancelDocumentAI = useCallback((notifyHost = true) => {
    const active = aiRequestRef.current;
    if (!active) {
      // A save may still be draining before the request is sent. Clearing this
      // token makes that continuation stop instead of starting AI while leaving.
      aiInFlightRef.current = false;
      return;
    }
    if (notifyHost) {
      bridge.send({ type: 'cancelDocumentAI', payload: { requestId: active.requestId } });
    }
    const currentEditor = editorRef.current;
    if (currentEditor) restoreDocumentAI(currentEditor, active);
    aiRequestRef.current = null;
    aiInFlightRef.current = false;
    setAIRunning(false);
    setAIDetail(null);
  }, []);

  // Which formatting buttons are lit depends on the SELECTION, so the menu has to
  // redraw on every transaction and not only on edits.
  const onUpdate = useCallback(() => redraw((n) => n + 1), []);

  /**
   * A citation is not an external URL. Swift rejects any non-HTTP scheme from
   * openExternalURL, so routing `ticker-pdf://` there did nothing at all — the
   * click was simply swallowed. Citations go to the PDF pane instead.
   */
  const openLink = useCallback((href: string) => {
    if (href.startsWith(PDF_URL_PREFIX)) {
      bridge.send({ type: 'openPdfDestination', payload: { streamId: stream.id, url: href } });
      return;
    }
    bridge.send({ type: 'openExternalURL', payload: { url: href } });
  }, [stream.id]);

  const saveImageToAssets = useCallback(async (blob: Blob): Promise<string> => {
    const requestId = crypto.randomUUID();
    const data = await readBlobAsBase64(blob);

    return new Promise((resolve, reject) => {
      const timeout = window.setTimeout(() => {
        unsubscribe();
        reject(new Error('Timed out while saving image.'));
      }, 15_000);
      const unsubscribe = bridge.onMessage((message) => {
        if (message.payload?.requestId !== requestId) return;
        if (message.type === 'imageSaved' && typeof message.payload.assetUrl === 'string') {
          window.clearTimeout(timeout);
          unsubscribe();
          resolve(message.payload.assetUrl);
        } else if (message.type === 'imageSaveError') {
          window.clearTimeout(timeout);
          unsubscribe();
          reject(new Error(
            typeof message.payload.error === 'string' ? message.payload.error : 'Failed to save image.',
          ));
        }
      });

      bridge.send({
        type: 'saveImage',
        payload: { streamId: stream.id, data, requestId },
      });
    });
  }, [stream.id]);

  useEffect(() => {
    if (!host.current) return undefined;

    const created = createRichTextEditor({
      parent: host.current,
      markdown: stream.document?.markdown ?? '',
      // Every streamed frame is temporary until completion. Letting any one of
      // them arm autosave stores a reply the user never actually received.
      onChange: () => {
        if (!aiInFlightRef.current) sessionRef.current?.documentChanged();
      },
      onUpdate,
      onOpenLink: openLink,
    });

    const session = new DocumentSession({
      streamId: stream.id,
      editor: created,
      revision: stream.document?.revision ?? 0,
      spans: (stream.spans ?? []).map(spanFromJSON),
      pendingAppends: decodePendingAppends(stream.pendingAppends),
      transport: {
        // Spelled out rather than spread: the contract checker verifies this
        // payload statically against bridge.v2.json, and can only do that for a
        // literal.
        save: ({ streamId, markdown, baseRevision, spans, resolvedPendingThrough }) => bridge.sendAsync<{ revision: number }>(
          'saveStreamDocument',
          { streamId, markdown, baseRevision, spans, resolvedPendingThrough },
        ),
        reload: (streamId) => bridge.send({ type: 'loadStream', payload: { id: streamId } }),
        onSaveStateChange: setSaveState,
        onError: (message) => addToast(message, 'error'),
      },
    });

    editorRef.current = created;
    sessionRef.current = session;
    setEditor(created);

    const scroller = host.current.closest('.stream-content') as HTMLElement;
    let scrollSaveTimer: number | undefined;
    const sendScrollPosition = () => bridge.send({
      type: 'saveScrollPosition',
      payload: { streamId: stream.id, offset: Math.max(0, scroller.scrollTop) },
    });
    const saveScrollPosition = () => {
      window.clearTimeout(scrollSaveTimer);
      scrollSaveTimer = window.setTimeout(() => {
        scrollSaveTimer = undefined;
        sendScrollPosition();
      }, 1_000);
    };
    scroller.scrollTop = Math.max(0, stream.document?.scrollOffset ?? 0);
    scroller.addEventListener('scroll', saveScrollPosition, { passive: true });

    return () => {
      scroller.removeEventListener('scroll', saveScrollPosition);
      if (scrollSaveTimer !== undefined) {
        window.clearTimeout(scrollSaveTimer);
        sendScrollPosition();
      }
      const active = aiRequestRef.current;
      if (active) {
        bridge.send({ type: 'cancelDocumentAI', payload: { requestId: active.requestId } });
        restoreDocumentAI(created, active);
        aiRequestRef.current = null;
      }
      aiInFlightRef.current = false;
      editorRef.current = null;
      sessionRef.current = null;
      setEditor(null);

      // Saving a document the user just deleted writes a row for a stream that is
      // gone, and reports the failure as if their writing were at risk.
      if (deleting.current) {
        created.destroy();
        return;
      }

      // The backstop, for unmounts that did not come through `leave` below —
      // nothing may tear the editor down before what is pending has been written,
      // because the write reads the document.
      void session.destroy().then((saved) => {
        if (!saved) addToast('Some changes could not be saved before leaving the stream.', 'error');
        created.destroy();
      });
    };
  }, [addToast, onUpdate, openLink, stream.id]);

  useEffect(() => {
    if (!editor) return undefined;
    let live = true;

    // ponytail: uploads land at the live cursor; keep a mapped bookmark if upload
    // latency makes cursor drift observable.
    const insertFile = async (file: File) => {
      try {
        const src = await saveImageToAssets(file);
        if (!live) {
          // ponytail: this leaves the saved asset orphaned; add a host append
          // command when uploads must finish after navigation.
          addToast('Image was saved but not added because the stream closed. Paste it again.', 'error');
          return;
        }
        insertImage(editor.view, {
          src,
          alt: file.name.replace(/\.[^.]+$/, '') || 'image',
        });
        editor.view.focus();
      } catch (error) {
        if (!live) return;
        addToast(error instanceof Error ? error.message : 'Failed to insert image.', 'error');
      }
    };
    const paste = (event: ClipboardEvent) => {
      const file = Array.from(event.clipboardData?.items ?? [])
        .find((item) => item.type.startsWith('image/'))?.getAsFile();
      if (!file) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      const text = event.clipboardData?.getData('text/plain') ?? '';
      if (text.trim()) {
        editor.view.pasteText(text, event);
        return;
      }
      void insertFile(file);
    };
    const drop = (event: DragEvent) => {
      const file = Array.from(event.dataTransfer?.files ?? [])
        .find((candidate) => candidate.type.startsWith('image/'));
      if (!file) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      void insertFile(file);
    };
    const dragover = (event: DragEvent) => {
      if (Array.from(event.dataTransfer?.items ?? []).some((item) => item.type.startsWith('image/'))) {
        event.preventDefault();
      }
    };

    editor.view.dom.addEventListener('paste', paste, true);
    editor.view.dom.addEventListener('drop', drop, true);
    editor.view.dom.addEventListener('dragover', dragover, true);
    return () => {
      live = false;
      editor.view.dom.removeEventListener('paste', paste, true);
      editor.view.dom.removeEventListener('drop', drop, true);
      editor.view.dom.removeEventListener('dragover', dragover, true);
    };
  }, [addToast, editor, saveImageToAssets]);

  useEffect(() => {
    if (!editor || !pendingMatchText) return;
    selectText(editor.view, pendingMatchText);
    onClearPendingMatch?.();
  }, [editor, onClearPendingMatch, pendingMatchText]);

  const startDocumentAI = useCallback(async (
    verb: Exclude<DocumentAIVerb, 'challenge'> = 'develop',
    instruction?: string,
  ) => {
    const currentEditor = editorRef.current;
    const session = sessionRef.current;
    if (!currentEditor || !session || aiInFlightRef.current) return;

    // Clear any already-armed save before streaming begins. Merely suppressing the
    // chunks is insufficient: a timer from the edit that started the request can
    // otherwise fire over the first half of the reply.
    aiInFlightRef.current = true;
    const saved = await session.saveNow();
    if (!aiInFlightRef.current || editorRef.current !== currentEditor || sessionRef.current !== session) {
      aiInFlightRef.current = false;
      return;
    }
    if (!saved) {
      aiInFlightRef.current = false;
      addToast('Save your changes before asking AI to rewrite them.', 'error');
      return;
    }

    const target = documentAITarget(currentEditor);
    if (!target) {
      aiInFlightRef.current = false;
      addToast('Select text or place the cursor in a paragraph to send.', 'info');
      return;
    }

    let range = { from: target.from, to: target.to };
    if (verb === 'ask' || verb === 'define') {
      const $to = currentEditor.view.state.doc.resolve(target.to);
      const at = $to.depth ? $to.after() : target.to;
      range = { from: at, to: at };
    }

    const requestId = crypto.randomUUID();
    aiRequestRef.current = {
      requestId,
      editor: currentEditor,
      original: currentEditor.view.state.doc.slice(range.from, range.to),
      stream: streamAIMarkdown(currentEditor.view, range),
      verb,
    };
    setAIRunning(true);
    setAIDetail('AI is writing');
    // ponytail: text-only first slice; collect selected image nodes when this
    // page exposes multimodal document-AI actions.
    bridge.send({
      type: 'thinkDocument',
      payload: {
        requestId,
        streamId: stream.id,
        query: instruction ?? target.text,
        context: instruction ? target.text : undefined,
        sourceScope: stream.sourceScope ?? 'auto',
        verb,
        imageURLs: [],
      },
    });
  }, [addToast, stream.id, stream.sourceScope]);

  const openDocumentAIPrompt = useCallback((verb: 'ask' | 'rewrite') => {
    const currentEditor = editorRef.current;
    if (!currentEditor || !documentAITarget(currentEditor)) {
      addToast('Select text or place the cursor in a paragraph to use as context.', 'info');
      return;
    }
    setPromptValue('');
    setPromptVerb(verb);
  }, [addToast]);

  const closeDocumentAIPrompt = useCallback(() => {
    setPromptVerb(null);
    setPromptValue('');
  }, []);

  const sendDocumentAIPrompt = useCallback(() => {
    const instruction = promptValue.trim();
    if (!promptVerb || !instruction) return;
    const verb = promptVerb;
    closeDocumentAIPrompt();
    void startDocumentAI(verb, instruction);
  }, [closeDocumentAIPrompt, promptValue, promptVerb, startDocumentAI]);

  /**
   * Leaving is not a render, it is a write that can fail.
   *
   * Cleanup cannot gate it: by the time an effect's teardown runs, the navigation
   * has already happened, so a failed save could only be reported after the editor
   * — the one place the text still existed — was gone. So the save happens first
   * and the page is left only if it actually landed.
   */
  const leave = useCallback(async () => {
    cancelDocumentAI();
    const session = sessionRef.current;
    if (!session) return onBack();
    setLeaving(true);
    if (await session.destroy()) return onBack();
    setLeaving(false);
    addToast('Your changes could not be saved, so this stream stayed open.', 'error');
  }, [addToast, cancelDocumentAI, onBack]);

  const remove = useCallback(() => {
    deleting.current = true;
    onDelete();
  }, [onDelete]);

  useEffect(() => bridge.onMessage((message) => {
    const session = sessionRef.current;
    if (!session) return;
    const payload = message.payload as Record<string, unknown> | undefined;

    if (message.type === 'getEditorSelection') {
      const requestId = payload?.requestId;
      if (typeof requestId !== 'string') return;
      const view = editorRef.current?.view;
      const selection = view?.state.selection;
      const text = view && selection && !selection.empty
        ? view.state.doc.textBetween(selection.from, selection.to, '\n', '')
        : '';
      bridge.send({ type: 'editorSelection', payload: { requestId, text } });
      return;
    }

    const activeAI = aiRequestRef.current;

    if (message.type === 'aiOperationChanged') {
      if (!activeAI || payload?.requestId !== activeAI.requestId) return;
      const detail = typeof payload.message === 'string' ? payload.message : payload.state;
      if (typeof detail === 'string') setAIDetail(`AI ${detail}`);
      return;
    }

    if (message.type === 'documentModelSelected') {
      if (!activeAI || payload?.requestId !== activeAI.requestId || typeof payload.modelId !== 'string') return;
      activeAI.model = payload.modelId;
      setAIDetail(`AI model: ${payload.modelId}`);
      return;
    }

    if (message.type === 'documentAIChunk') {
      if (!activeAI || payload?.requestId !== activeAI.requestId || typeof payload.chunk !== 'string' || !payload.chunk) return;
      activeAI.stream.push(payload.chunk);
      return;
    }

    if (message.type === 'documentAIError') {
      if (!activeAI || payload?.requestId !== activeAI.requestId) return;
      const cancelled = payload.errorCode === 'cancelled';
      const error = typeof payload.error === 'string' ? payload.error : 'AI request failed.';
      cancelDocumentAI(false);
      if (!cancelled) addToast(error, 'error');
      return;
    }

    if (message.type === 'documentAIComplete') {
      if (!activeAI || payload?.requestId !== activeAI.requestId) return;
      const rawOutput = activeAI.stream.markdown.trim();
      if (!rawOutput) {
        // The chunks have already replaced the target, so accepting an empty
        // buffer here permanently deletes the text the request was meant to edit.
        cancelDocumentAI(false);
        addToast('AI returned empty output.', 'error');
        return;
      }

      const { view } = activeAI.editor;

      const citations = parseDocumentAICitations(payload.citations);
      let finalOutput = rawOutput;
      let provenanceLine: string | null = null;
      if (citations) {
        const result = swapCitationMarkersWithMetadata(rawOutput, citations);
        finalOutput = result.text;
        provenanceLine = buildProvenanceLine(result.swappedCitations);
      } else if (payload.sourceContextMode === 'none') {
        provenanceLine = '*From model knowledge.*';
      } else if (payload.sourceContextMode === 'unavailable') {
        provenanceLine = '*Source retrieval unavailable — answered from model knowledge.*';
      }
      if (provenanceLine) finalOutput = `${finalOutput}\n\n${provenanceLine}`;

      // The citation pass has to join the stream's history event. Otherwise Undo
      // stops on the raw provider markers instead of restoring the user's text.
      activeAI.stream.finalize(finalOutput);
      const written = activeAI.stream.done();
      const span = {
        spanId: crypto.randomUUID(),
        ...written,
        origin: 'ai' as const,
        requestId: activeAI.requestId,
        meta: { model: activeAI.model ?? null, verb: activeAI.verb },
        textHash: hashProvenanceText(view.state.doc, written),
        createdAt: Date.now(),
      };
      const tr = addProvenanceSpans(setAIWritingRange(view.state.tr, null), [span])
        .setMeta('addToHistory', false);
      view.dispatch(tr);

      aiRequestRef.current = null;
      aiInFlightRef.current = false;
      setAIRunning(false);
      setAIDetail(null);
      session.documentChanged();
      return;
    }

    if (message.type === 'streamDocumentAppended') {
      session.documentAppended({
        streamId: String(payload?.streamId ?? ''),
        fragment: String(payload?.fragment ?? ''),
        revision: Number(payload?.revision),
        // Offsets into the fragment's own markdown, which is all the host can know
        // without parsing the document. Not forwarding them — which is what this
        // did — dropped the provenance of everything the AI and the quick panel
        // wrote while the stream was open.
        spans: payload?.spans as ProvenanceSpanJSON[] | undefined,
      });
      return;
    }

    if (message.type === 'streamDocumentConflict') {
      cancelDocumentAI();
      const conflict = payload as Partial<StreamDocumentConflictPayload> | undefined;
      session.documentConflict({
        streamId: String(conflict?.streamId ?? ''),
        markdown: String(conflict?.markdown ?? ''),
        revision: Number(conflict?.revision),
        spans: conflict?.spans?.map(spanFromJSON),
        pendingAppends: decodePendingAppends(
          Array.isArray(conflict?.pendingAppends) ? conflict.pendingAppends : [],
        ),
      });
      return;
    }

    if (message.type === 'flushEditor') {
      // The host is closing or quitting and waits for this before it does. It is
      // acknowledged either way — leaving the host hung is worse than a failed save
      // it can see — but a failure still shows as an error and raises a toast.
      const requestId = payload?.requestId;
      if (typeof requestId !== 'string') return;
      cancelDocumentAI();
      void session.saveNow().then((saved) => {
        // Reported truthfully: the host cancels quitting on a false, because
        // closing over an editor that could not save discards the only copy.
        bridge.send({ type: 'editorFlushed', payload: { requestId, saved } });
      });
    }
  }), [addToast, cancelDocumentAI, stream.id]);

  /**
   * A reload this session asked for, after an append it could not reconcile.
   *
   * It arrives as new props rather than as a message: App already decodes
   * streamLoaded — including the request-id check that stops a stale response
   * being applied — and the stream id does not change, so React keeps this
   * component mounted and nothing else would apply the document. Reading the
   * decoded props avoids a second decoder that can disagree with the first, which
   * is exactly what happened: the payload nests under `stream`, and a handler
   * reading `payload.document` returned early every time.
   */
  useEffect(() => {
    const session = sessionRef.current;
    const document = stream.document;
    if (!session || !document) return;
    if (document.revision <= session.currentRevision) return;
    cancelDocumentAI();
    session.documentLoaded({
      markdown: document.markdown,
      revision: document.revision,
      spans: (stream.spans ?? []).map(spanFromJSON),
      // The reloaded document brings its own rows. Without them the session could
      // never let the store forget another one, and a row that outlives the
      // revision it was recorded at can never be replayed.
      pendingAppends: decodePendingAppends(stream.pendingAppends),
    });
  }, [cancelDocumentAI, stream.document, stream.pendingAppends, stream.spans]);

  const saveTitle = useCallback(() => {
    const next = title.trim() || 'Untitled';
    setTitle(next);
    if (next !== stream.title) {
      bridge.send({ type: 'updateStreamTitle', payload: { id: stream.id, title: next } });
    }
  }, [stream.id, stream.title, title]);

  const run = (command: Command) => () => {
    if (!editor) return;
    command(editor.view.state, editor.view.dispatch, editor.view);
    editor.view.focus();
  };

  const formats = editor ? activeFormats(editor.view.state) : null;

  const formatButton = (label: string, active: boolean, command: Command, hint: string) => (
    <button
      key={label}
      type="button"
      className={`selection-action-button ${active ? 'selection-action-button--active' : ''}`}
      title={hint}
      // Keep the selection: the editor must not lose focus to the button.
      onMouseDown={(event) => event.preventDefault()}
      onClick={run(command)}
    >
      {label}
    </button>
  );

  return (
    <div className="stream-editor">
      <header className="stream-header">
        <button onClick={leave} disabled={leaving} className="back-button">← Back</button>
        <input
          type="text"
          className="stream-title-input"
          value={title}
          onChange={(event) => setTitle(event.target.value)}
          onBlur={saveTitle}
          onKeyDown={(event) => { if (event.key === 'Enter') event.currentTarget.blur(); }}
        />
        <div className="stream-header-actions">
          <span
            className={`stream-save-status stream-save-status--${saveState}`}
            role="status"
            aria-live="polite"
            aria-label={SAVE_LABEL[saveState]}
            title={SAVE_LABEL[saveState]}
          >
            <span className="stream-save-status-dot" aria-hidden="true" />
            <span className="stream-save-status-label">{SAVE_LABEL[saveState]}</span>
          </span>
          <button
            onClick={() => setXray((value) => !value)}
            className={`stream-xray-button ${xray ? 'stream-xray-button--active' : ''}`}
            title="Toggle provenance x-ray"
          >
            Xray
          </button>
          <button onClick={remove} className="delete-button" title="Delete stream">Delete</button>
        </div>
      </header>

      {promptVerb && (
        <Modal
          className="ai-prompt-dialog"
          aria-labelledby="richtext-ai-prompt-title"
          onRequestClose={closeDocumentAIPrompt}
        >
          <h2 id="richtext-ai-prompt-title">
            {promptVerb === 'rewrite' ? 'Rewrite' : 'Send & Prompt'}
          </h2>
          <p>The selected text will be attached as context.</p>
          <textarea
            className="ai-prompt-input"
            value={promptValue}
            onChange={(event) => setPromptValue(event.target.value)}
            onKeyDown={(event) => {
              if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') {
                event.preventDefault();
                sendDocumentAIPrompt();
              } else if (event.key === 'Escape') {
                event.preventDefault();
                closeDocumentAIPrompt();
              }
            }}
            placeholder={promptVerb === 'rewrite'
              ? 'How should this be rewritten?'
              : 'Ask a question or give an instruction…'}
            autoFocus
            rows={5}
          />
          <div className="ai-prompt-actions">
            <button
              className="ai-prompt-cancel"
              type="button"
              onClick={closeDocumentAIPrompt}
            >
              Cancel
            </button>
            <button
              className="ai-prompt-send"
              type="button"
              aria-label="Send prompt to AI"
              onClick={sendDocumentAIPrompt}
              disabled={!promptValue.trim()}
            >
              Send
            </button>
          </div>
        </Modal>
      )}

      {formats && (
        <div className="stream-format-bar">
          <button
            type="button"
            className="selection-action-button selection-action-button--text selection-action-button--ai"
            aria-label={aiRunning ? 'Stop document AI' : 'Send to AI'}
            title={aiDetail ?? 'Send the selection or current paragraph to AI'}
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => { if (aiRunning) cancelDocumentAI(); else void startDocumentAI(); }}
          >
            {aiRunning ? 'Stop AI' : 'Send'}
          </button>
          <button
            type="button"
            className="selection-action-button selection-action-button--text selection-action-button--ai"
            aria-label="Send and prompt AI"
            disabled={aiRunning}
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => openDocumentAIPrompt('ask')}
          >
            Send &amp; Prompt
          </button>
          <button
            type="button"
            className="selection-action-button selection-action-button--text selection-action-button--ai"
            aria-label="Ask with AI"
            disabled={aiRunning}
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => { void startDocumentAI('ask'); }}
          >
            Ask
          </button>
          <button
            type="button"
            className="selection-action-button selection-action-button--text selection-action-button--ai"
            aria-label="Define with AI"
            disabled={aiRunning}
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => { void startDocumentAI('define'); }}
          >
            Define
          </button>
          <button
            type="button"
            className="selection-action-button selection-action-button--text selection-action-button--ai"
            aria-label="Rewrite with AI"
            disabled={aiRunning}
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => openDocumentAIPrompt('rewrite')}
          >
            Rewrite…
          </button>
          {formatButton('B', formats.bold, toggleBold, 'Bold ⌘B')}
          {formatButton('I', formats.italic, toggleItalic, 'Italic ⌘I')}
          {formatButton('U', formats.underline, toggleUnderline, 'Underline ⌘U')}
          {formatButton('Code', formats.code, toggleCode, 'Code')}
          {formatButton('H2', formats.heading === 2, toggleHeading(2), 'Heading')}
          {formatButton('H3', formats.heading === 3, toggleHeading(3), 'Subheading')}
          {formatButton('List', formats.bulletList, toggleBulletList, 'Bullets')}
          {formatButton('1.', formats.orderedList, toggleOrderedList, 'Numbers')}
          {formatButton('Quote', formats.blockquote, toggleBlockquote, 'Quote')}
        </div>
      )}

      <div className="stream-body">
        <div className="stream-content">
          <div className={`document-editor-shell ${xray ? 'richtext-xray' : ''}`}>
            <div ref={host} />
          </div>
        </div>
      </div>
    </div>
  );
}
