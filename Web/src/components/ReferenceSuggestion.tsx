import { ReactRenderer } from '@tiptap/react';
import tippy, { Instance as TippyInstance } from 'tippy.js';
import { SuggestionOptions, SuggestionProps } from '@tiptap/suggestion';
import { forwardRef, useEffect, useImperativeHandle, useState } from 'react';
import { Cell } from '../types/models';
import { getShortId } from '../utils/references';
import { deriveCellTitle } from '../utils/cellTitle';

interface SuggestionItem {
  id: string;
  label: string;
  shortId: string;
  type: string;
}

interface SuggestionListProps {
  items: SuggestionItem[];
  command: (item: SuggestionItem) => void;
}

interface SuggestionListRef {
  onKeyDown: (event: KeyboardEvent) => boolean;
}

const SuggestionList = forwardRef<SuggestionListRef, SuggestionListProps>(
  ({ items, command }, ref) => {
    const [selectedIndex, setSelectedIndex] = useState(0);

    const selectItem = (index: number) => {
      const item = items[index];
      if (item) {
        command(item);
      }
    };

    useEffect(() => {
      setSelectedIndex(0);
    }, [items]);

    useImperativeHandle(ref, () => ({
      onKeyDown: (event: KeyboardEvent) => {
        if (event.key === 'ArrowUp') {
          setSelectedIndex((prev) => (prev + items.length - 1) % items.length);
          return true;
        }

        if (event.key === 'ArrowDown') {
          setSelectedIndex((prev) => (prev + 1) % items.length);
          return true;
        }

        if (event.key === 'Enter') {
          selectItem(selectedIndex);
          return true;
        }

        return false;
      },
    }));

    if (items.length === 0) {
      return (
        <div className="reference-suggestion-list">
          <div className="reference-suggestion-item reference-suggestion-item--empty">
            No cells found
          </div>
        </div>
      );
    }

    return (
      <div className="reference-suggestion-list">
        {items.map((item, index) => (
          <button
            key={item.id}
            className={`reference-suggestion-item ${
              index === selectedIndex ? 'reference-suggestion-item--selected' : ''
            }`}
            onClick={() => selectItem(index)}
          >
            <span className="reference-suggestion-label">{item.label}</span>
            <span className="reference-suggestion-id">@block-{item.shortId}</span>
          </button>
        ))}
      </div>
    );
  }
);

SuggestionList.displayName = 'SuggestionList';

export function createReferenceSuggestion(
  getCells: () => Cell[]
): Omit<SuggestionOptions<SuggestionItem>, 'editor'> {
  return {
    char: '@',
    allowSpaces: false,
    startOfLine: false,

    items: ({ query }): SuggestionItem[] => {
      const cells = getCells();
      const lowerQuery = query.toLowerCase().trim();

      return cells
        .filter((cell) => {
          // If no query, show all cells
          if (!lowerQuery) return true;

          // Filter by title, blockName, short ID, content, or type
          const blockName = cell.blockName?.toLowerCase() || '';
          const shortId = getShortId(cell.id);
          const content = cell.content.replace(/<[^>]*>/g, '').toLowerCase();
          const cellType = cell.type.toLowerCase();
          const title = deriveCellTitle(cell).toLowerCase();

          return (
            title.includes(lowerQuery) ||
            blockName.includes(lowerQuery) ||
            shortId.includes(lowerQuery) ||
            content.includes(lowerQuery) ||
            cellType.includes(lowerQuery)
          );
        })
        // Sort by order to maintain document order
        .sort((a, b) => a.order - b.order)
        .map((cell) => {
          const label = deriveCellTitle(cell);

          return {
            id: cell.id,
            label,
            // Always use the 4-char shortId for the reference syntax (never blockName)
            // This ensures the regex @block-([a-zA-Z0-9]{3,}) always matches correctly
            shortId: getShortId(cell.id),
            type: cell.type,
          };
        });
    },

    render: () => {
      let component: ReactRenderer<SuggestionListRef>;
      let popup: TippyInstance[];

      return {
        onStart: (props: SuggestionProps<SuggestionItem>) => {
          component = new ReactRenderer(SuggestionList, {
            props,
            editor: props.editor,
          });

          if (!props.clientRect) return;

          popup = tippy('body', {
            getReferenceClientRect: props.clientRect as () => DOMRect,
            appendTo: () => document.body,
            content: component.element,
            showOnCreate: true,
            interactive: true,
            trigger: 'manual',
            placement: 'bottom-start',
          });
        },

        onUpdate(props: SuggestionProps<SuggestionItem>) {
          component.updateProps(props);

          if (!props.clientRect) return;

          popup[0].setProps({
            getReferenceClientRect: props.clientRect as () => DOMRect,
          });
        },

        onKeyDown(props: { event: KeyboardEvent }) {
          if (props.event.key === 'Escape') {
            popup[0].hide();
            return true;
          }

          return component.ref?.onKeyDown(props.event) ?? false;
        },

        onExit() {
          popup[0].destroy();
          component.destroy();
        },
      };
    },
  };
}
