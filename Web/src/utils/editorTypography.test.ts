import { describe, expect, it } from 'vitest';
import {
  DEFAULT_EDITOR_TYPOGRAPHY,
  editorFontStack,
  normalizeEditorTypography,
  type EditorTypographySettings,
} from './editorTypography';

describe('editor typography', () => {
  it('uses one default for startup and settings', () => {
    expect(normalizeEditorTypography(null)).toEqual(DEFAULT_EDITOR_TYPOGRAPHY);
  });

  it('rejects unknown fonts and bounds numeric settings', () => {
    const raw = {
      editorFont: 'unknown',
      editorFontSize: 40,
      editorLineSpacing: 1,
    } as unknown as EditorTypographySettings;

    expect(normalizeEditorTypography(raw)).toEqual({
      editorFont: 'systemSans',
      editorFontSize: 24,
      editorLineSpacing: 1.3,
    });
  });

  it('shares the preview and editor font stack', () => {
    expect(editorFontStack('monoSans')).toContain('SF Mono');
  });
});
