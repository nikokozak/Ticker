import type { ChangeDesc } from '@codemirror/state';

export interface PendingPDFAnchorSelection {
  from: number;
  to: number;
}

export interface PDFAnchorLinkEdit {
  from: number;
  to: number;
  insert: string;
  markdown: string;
}

export function mapPendingPDFAnchorSelection(
  selection: PendingPDFAnchorSelection,
  changes: ChangeDesc
): PendingPDFAnchorSelection | null {
  const from = changes.mapPos(selection.from, 1);
  const to = changes.mapPos(selection.to, -1);
  if (from >= to) return null;
  return { from, to };
}

export function buildTickerPDFLinkURL(args: { sourceId: string; highlightId: string; page: number }): string {
  return `ticker-pdf://${args.sourceId}?highlight=${encodeURIComponent(args.highlightId)}&page=${args.page}`;
}

export function buildPDFAnchorLinkEdit(
  markdown: string,
  selection: PendingPDFAnchorSelection,
  linkURL: string
): PDFAnchorLinkEdit | null {
  const from = Math.max(0, Math.min(selection.from, markdown.length));
  const to = Math.max(from, Math.min(selection.to, markdown.length));
  const selectedText = markdown.slice(from, to);
  if (!selectedText.trim()) return null;

  const linkText = selectedText
    .replace(/\\/g, '\\\\')
    .replace(/\]/g, '\\]');
  const insert = `[${linkText}](${linkURL})`;

  return {
    from,
    to,
    insert,
    markdown: `${markdown.slice(0, from)}${insert}${markdown.slice(to)}`,
  };
}
