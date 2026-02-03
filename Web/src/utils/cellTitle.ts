import type { Cell } from '../types/models';
import { stripHtml } from './html';

function normalizeTitle(value: string | null | undefined): string | null {
  if (!value) return null;
  const trimmed = value.replace(/\s+/g, ' ').trim();
  return trimmed.length > 0 ? trimmed : null;
}

export function extractFirstHeadingFromHtml(html: string): string | null {
  const normalizedHtml = normalizeTitle(html);
  if (!normalizedHtml) return null;

  const doc = new DOMParser().parseFromString(normalizedHtml, 'text/html');
  const heading = doc.body.querySelector('h1, h2, h3, h4, h5, h6');
  return normalizeTitle(heading?.textContent ?? null);
}

export function snippetFromHtml(html: string, maxLen = 80): string | null {
  const text = normalizeTitle(stripHtml(html));
  if (!text) return null;
  if (text.length <= maxLen) return text;
  return `${text.slice(0, maxLen - 1)}…`;
}

export function deriveCellTitle(cell: Pick<Cell, 'content' | 'blockName' | 'originalPrompt'>): string {
  const fromHeading = extractFirstHeadingFromHtml(cell.content);
  if (fromHeading) return fromHeading;

  const fromBlockName = normalizeTitle(cell.blockName);
  if (fromBlockName) return fromBlockName;

  const fromPrompt = normalizeTitle(cell.originalPrompt);
  if (fromPrompt) return fromPrompt;

  return snippetFromHtml(cell.content) ?? 'Untitled';
}

