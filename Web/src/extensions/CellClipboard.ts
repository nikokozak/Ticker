import { Extension } from '@tiptap/core';
import { Plugin } from '@tiptap/pm/state';
import { Fragment, Slice } from '@tiptap/pm/model';
import { IS_DEV, debugLog } from '../utils/debug';

/**
 * CellClipboard
 *
 * Problem:
 * - Copying a selection that spans multiple `cellBlock`s puts whole `cellBlock` nodes on the clipboard,
 *   including their UUID `attrs.id`.
 * - Pasting those nodes creates new `cellBlock`s that *reuse* the same UUIDs.
 * - Swift persistence is "upsert by id", so duplicated UUIDs collide and content "disappears" on reload.
 *
 * Fix:
 * - On paste, rewrite `cellBlock.attrs.id` to a fresh UUID for every pasted `cellBlock` node instance.
 * - We do *not* attempt to rewrite references inside the content; pasted blocks still refer to originals.
 */
export const CellClipboard = Extension.create({
  name: 'cellClipboard',

  addProseMirrorPlugins() {
    return [
      new Plugin({
        props: {
          transformPasted: (slice) => {
            const cellBlockType = this.editor.schema.nodes.cellBlock;
            if (!cellBlockType) return slice;

            let rewritten = 0;

            const rewriteFragment = (fragment: Fragment): Fragment => {
              const children = [];
              for (let i = 0; i < fragment.childCount; i++) {
                const child = fragment.child(i);

                if (child.type === cellBlockType) {
                  const newId = crypto.randomUUID();
                  rewritten++;
                  children.push(
                    child.type.create(
                      { ...child.attrs, id: newId },
                      rewriteFragment(child.content),
                      child.marks
                    )
                  );
                  continue;
                }

                if (child.content && child.content.size > 0) {
                  children.push(
                    child.type.create(
                      child.attrs,
                      rewriteFragment(child.content),
                      child.marks
                    )
                  );
                } else {
                  children.push(child);
                }
              }
              return Fragment.fromArray(children);
            };

            const nextContent = rewriteFragment(slice.content);
            if (rewritten > 0 && IS_DEV) {
              debugLog(`[CellClipboard] Rewrote ${rewritten} pasted cellBlock id(s)`);
            }

            return new Slice(nextContent, slice.openStart, slice.openEnd);
          },
        },
      }),
    ];
  },
});

