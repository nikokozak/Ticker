import { useCallback, useEffect, useRef, useState } from 'react';
import type { Command } from 'prosemirror-state';
import { createRoot } from 'react-dom/client';
import { createRichTextEditor, type RichTextEditor } from './editor';
import { activeFormats, toggleBlockquote, toggleBold, toggleBulletList, toggleHeading, toggleItalic, toggleOrderedList, toggleUnderline } from './commands';
import './editor.css';
import '../styles/index.css';

/**
 * A bench for judging the editor by feel, which is the only way this particular
 * problem has ever been judged correctly. Not part of the app build — Vite only
 * bundles index.html — so it costs the product nothing.
 *
 *   npm run dev, then open /richtext.html
 *
 * The right-hand pane is the markdown that would be STORED. Watching it while
 * typing is the fastest way to catch the editor writing something ugly, and the
 * fastest way to confirm the left-hand pane never shows syntax.
 */

const SAMPLE = `# Reading a document

A paragraph with **bold**, *italic*, <u>underlined</u> and \`inline code\`, so the
cursor has something to walk through. Try arrowing across the formatted words: there
is nothing hidden between the letters, because the markers are not in the document.

## Citations are the reason this was rewritten

This sentence cites [a section of a paper](ticker-pdf://source-1?page=12&q=the%20quoted%20text)
in the middle of a paragraph, next to [an external link](https://example.com/a/very/long/url?with=query&and=more#fragment)
whose URL is long enough to have wrecked the old layout. Neither one expands.

> A quotation, to check that block formatting nests.

* A tight list
* with a second item
* and a [link](https://example.com) inside it

1. An ordered list
2. that keeps its numbering

\`\`\`ts
const x: number = 1; // a fenced block keeps its language
\`\`\`

Press Shift+Enter for a line break inside a paragraph,
like this one. Press it twice for a blank line. Select any text and use the buttons
above, or ⌘B / ⌘I / ⌘U.
`;

function Toolbar({ editor }: { editor: RichTextEditor }) {
  const formats = activeFormats(editor.view.state);

  const run = (command: Command) => () => {
    command(editor.view.state, editor.view.dispatch, editor.view);
    editor.view.focus();
  };

  const button = (label: string, active: boolean, command: Command) => (
    <button
      key={label}
      type="button"
      onMouseDown={(event) => event.preventDefault()}
      onClick={run(command)}
      style={{
        padding: '4px 10px',
        border: '1px solid var(--color-border)',
        borderRadius: 'var(--radius)',
        background: active ? 'var(--color-accent-soft)' : 'var(--color-surface)',
        color: 'var(--color-text)',
        font: 'inherit',
        cursor: 'default',
      }}
    >
      {label}
    </button>
  );

  return (
    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', padding: 12, borderBottom: '1px solid var(--color-border)' }}>
      {button('Bold', formats.bold, toggleBold)}
      {button('Italic', formats.italic, toggleItalic)}
      {button('Underline', formats.underline, toggleUnderline)}
      {button('H2', formats.heading === 2, toggleHeading(2))}
      {button('H3', formats.heading === 3, toggleHeading(3))}
      {button('Bullets', formats.bulletList, toggleBulletList)}
      {button('Numbers', formats.orderedList, toggleOrderedList)}
      {button('Quote', formats.blockquote, toggleBlockquote)}
    </div>
  );
}

function Demo() {
  const host = useRef<HTMLDivElement>(null);
  const [editor, setEditor] = useState<RichTextEditor | null>(null);
  const [markdown, setMarkdown] = useState(SAMPLE);
  const [opened, setOpened] = useState<string | null>(null);
  const [, forceRender] = useState(0);
  // Which buttons are lit depends on the selection, so redraw on every transaction.
  const onUpdate = useCallback(() => forceRender((n) => n + 1), []);

  useEffect(() => {
    if (!host.current) return undefined;
    const created = createRichTextEditor({
      parent: host.current,
      markdown: SAMPLE,
      onChange: setMarkdown,
      onUpdate,
      // Not an alert: a modal dialog freezes the WKWebView and the browser tooling.
      onOpenLink: setOpened,
    });
    setEditor(created);
    return () => created.destroy();
  }, [onUpdate]);

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', height: '100vh', background: 'var(--color-bg)' }}>
      <div style={{ display: 'flex', flexDirection: 'column', minWidth: 0, borderRight: '1px solid var(--color-border)' }}>
        {editor ? <Toolbar editor={editor} /> : null}
        <div ref={host} style={{ flex: 1, overflow: 'auto' }} />
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <div style={{ padding: 12, borderBottom: '1px solid var(--color-border)', color: 'var(--color-text-secondary)', font: 'var(--type-ui-small) var(--font-editor-sans)' }}>
          {opened ? `the host would open: ${opened}` : 'what gets stored — this is what the AI and exports see'}
        </div>
        <pre style={{ flex: 1, margin: 0, padding: 16, overflow: 'auto', whiteSpace: 'pre-wrap', font: '12px var(--font-mono)', color: 'var(--color-text-secondary)' }}>
          {markdown}
        </pre>
      </div>
    </div>
  );
}

createRoot(document.getElementById('root') as HTMLElement).render(<Demo />);
