import { useCallback, useEffect, useRef, useState } from 'react';
import type { Command } from 'prosemirror-state';
import { bridge } from '../types/bridge';
import type { Stream } from '../types/models';
import { createRichTextEditor, type RichTextEditor } from '../richtext/editor';
import { DocumentSession, type SaveState } from '../richtext/session';
import { spanFromJSON, type ProvenanceSpanJSON } from '../richtext/provenance';
import { parseRawSpans, type PendingAppend } from '../richtext/pendingAppends';
import { useToastStore } from '../store/toastStore';
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
}

const PDF_URL_PREFIX = 'ticker-pdf://';

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

export function RichStreamEditor({ stream, onBack, onDelete }: RichStreamEditorProps) {
  const host = useRef<HTMLDivElement>(null);
  const editorRef = useRef<RichTextEditor | null>(null);
  const sessionRef = useRef<DocumentSession | null>(null);

  const [editor, setEditor] = useState<RichTextEditor | null>(null);
  const [saveState, setSaveState] = useState<SaveState>('saved');
  const [leaving, setLeaving] = useState(false);
  const deleting = useRef(false);
  const [xray, setXray] = useState(false);
  const [title, setTitle] = useState(stream.title);
  const [, redraw] = useState(0);
  const addToast = useToastStore((state) => state.addToast);

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

  useEffect(() => {
    if (!host.current) return undefined;

    const created = createRichTextEditor({
      parent: host.current,
      markdown: stream.document?.markdown ?? '',
      onChange: () => sessionRef.current?.documentChanged(),
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

    return () => {
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

  /**
   * Leaving is not a render, it is a write that can fail.
   *
   * Cleanup cannot gate it: by the time an effect's teardown runs, the navigation
   * has already happened, so a failed save could only be reported after the editor
   * — the one place the text still existed — was gone. So the save happens first
   * and the page is left only if it actually landed.
   */
  const leave = useCallback(async () => {
    const session = sessionRef.current;
    if (!session) return onBack();
    setLeaving(true);
    if (await session.destroy()) return onBack();
    setLeaving(false);
    addToast('Your changes could not be saved, so this stream stayed open.', 'error');
  }, [addToast, onBack]);

  const remove = useCallback(() => {
    deleting.current = true;
    onDelete();
  }, [onDelete]);

  useEffect(() => bridge.onMessage((message) => {
    const session = sessionRef.current;
    if (!session) return;
    const payload = message.payload as Record<string, unknown> | undefined;

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
      session.documentConflict({
        streamId: String(payload?.streamId ?? ''),
        markdown: String(payload?.markdown ?? ''),
        revision: Number(payload?.revision),
        spans: (payload?.spans as ProvenanceSpanJSON[] | undefined)?.map(spanFromJSON),
      });
      return;
    }

    if (message.type === 'flushEditor') {
      // The host is closing or quitting and waits for this before it does. It is
      // acknowledged either way — leaving the host hung is worse than a failed save
      // it can see — but a failure still shows as an error and raises a toast.
      const requestId = payload?.requestId;
      if (typeof requestId !== 'string') return;
      void session.saveNow().then((saved) => {
        // Reported truthfully: the host cancels quitting on a false, because
        // closing over an editor that could not save discards the only copy.
        bridge.send({ type: 'editorFlushed', payload: { requestId, saved } });
      });
    }
  }), [stream.id]);

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
    session.documentLoaded({
      markdown: document.markdown,
      revision: document.revision,
      spans: (stream.spans ?? []).map(spanFromJSON),
      // The reloaded document brings its own rows. Without them the session could
      // never let the store forget another one, and a row that outlives the
      // revision it was recorded at can never be replayed.
      pendingAppends: decodePendingAppends(stream.pendingAppends),
    });
  }, [stream.document, stream.pendingAppends, stream.spans]);

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

      {formats && (
        <div className="stream-format-bar">
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
