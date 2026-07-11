export const EDITOR_FONTS = ['systemSans', 'humanistSans', 'monoSans'] as const;

export type EditorFont = typeof EDITOR_FONTS[number];

export interface EditorTypographySettings {
  editorFont: EditorFont;
  editorFontSize: number;
  editorLineSpacing: number;
}

export const DEFAULT_EDITOR_TYPOGRAPHY: EditorTypographySettings = {
  editorFont: 'systemSans',
  editorFontSize: 16,
  editorLineSpacing: 1.55,
};

export function editorFontStack(font: EditorFont): string {
  switch (font) {
    case 'humanistSans':
      return '"Avenir Next", "SF Pro Text", -apple-system, BlinkMacSystemFont, system-ui, sans-serif';
    case 'monoSans':
      return '"SF Mono", "JetBrains Mono", "IBM Plex Sans", Menlo, "SF Pro Text", sans-serif';
    case 'systemSans':
      return '"SF Pro Text", -apple-system, BlinkMacSystemFont, system-ui, "Helvetica Neue", sans-serif';
  }
}

export function normalizeEditorTypography(
  raw: Partial<EditorTypographySettings> | null | undefined
): EditorTypographySettings {
  const merged = { ...DEFAULT_EDITOR_TYPOGRAPHY, ...(raw ?? {}) };
  const editorFont = EDITOR_FONTS.includes(merged.editorFont)
    ? merged.editorFont
    : DEFAULT_EDITOR_TYPOGRAPHY.editorFont;
  const editorFontSize = Number.isFinite(Number(merged.editorFontSize))
    ? Math.min(24, Math.max(13, Number(merged.editorFontSize)))
    : DEFAULT_EDITOR_TYPOGRAPHY.editorFontSize;
  const editorLineSpacing = Number.isFinite(Number(merged.editorLineSpacing))
    ? Math.min(2, Math.max(1.3, Number(merged.editorLineSpacing)))
    : DEFAULT_EDITOR_TYPOGRAPHY.editorLineSpacing;

  return {
    editorFont,
    editorFontSize: Number(editorFontSize.toFixed(1)),
    editorLineSpacing: Number(editorLineSpacing.toFixed(2)),
  };
}
