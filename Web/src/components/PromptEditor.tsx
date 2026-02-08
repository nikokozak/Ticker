import { useEditor, EditorContent } from '@tiptap/react';
import StarterKit from '@tiptap/starter-kit';
import Placeholder from '@tiptap/extension-placeholder';
import Mention from '@tiptap/extension-mention';
import { useEffect, useMemo } from 'react';
import { createReferenceSuggestion } from './ReferenceSuggestion';
import { useBlockStore } from '../store/blockStore';
import { Cell } from '../types/models';
import { filterReferenceSuggestionCells } from '../utils/referenceSuggestionCells';

interface PromptEditorProps {
  content: string;
  placeholder?: string;
  cellId?: string; // Current cell's ID to exclude from suggestions
  onChange: (content: string) => void;
  onSubmit?: () => void; // Called on Enter (without Shift)
}

/**
 * Minimal TipTap editor for prompt editing with @ reference support.
 * Used in CellOverlay for editing prompts before regenerating.
 */
export function PromptEditor({
  content,
  placeholder = 'Enter a prompt...',
  cellId,
  onChange,
  onSubmit,
}: PromptEditorProps) {
  // Get cells for reference suggestions (exclude current cell and empty spacing cells)
  const getCells = useMemo(() => {
    return (): Cell[] => {
      const blocks = useBlockStore.getState().getBlocksArray();
      return filterReferenceSuggestionCells(blocks, cellId);
    };
  }, [cellId]);

  const suggestionConfig = useMemo(
    () => createReferenceSuggestion(getCells),
    [getCells]
  );

  const editor = useEditor({
    extensions: [
      StarterKit.configure({
        heading: false,
        blockquote: false,
        codeBlock: false,
        horizontalRule: false,
      }),
      Placeholder.configure({
        placeholder,
      }),
      Mention.configure({
        HTMLAttributes: {
          class: 'cell-reference',
        },
        renderLabel({ node }) {
          // Always use shortId for the reference syntax to ensure regex compatibility
          // node.attrs.shortId is the 4-char hex prefix, set by ReferenceSuggestion
          return `@block-${node.attrs.shortId ?? node.attrs.id.substring(0, 4).toLowerCase()}`;
        },
        suggestion: suggestionConfig,
      }),
    ],
    content,
    editorProps: {
      attributes: {
        class: 'prompt-editor-content',
      },
      handleKeyDown: (_view, event) => {
        // Enter without Shift submits
        if (event.key === 'Enter' && !event.shiftKey) {
          event.preventDefault();
          onSubmit?.();
          return true;
        }
        return false;
      },
    },
    onUpdate: ({ editor }) => {
      onChange(editor.getHTML());
    },
  });

  // Update content when prop changes
  useEffect(() => {
    if (editor && content !== editor.getHTML()) {
      editor.commands.setContent(content);
    }
  }, [editor, content]);

  return (
    <div className="prompt-editor">
      <EditorContent editor={editor} />
    </div>
  );
}
