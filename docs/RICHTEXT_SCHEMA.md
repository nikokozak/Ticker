# Ticker rich-text schema (ProseMirror) — specification

Settled 2026-07-28 with Codex, against measurements from `spike/roundtrip.mjs`,
`spike/align.mjs` and `spike/decoys.mjs`. Constraints in force when this was written:
no migration corpus (all streams exportable and erasable), and appends already carry
whole-fragment provenance, so no raw-markdown-offset -> ProseMirror mapper is needed.

The schema should be: stock ProseMirror CommonMark, plus three measured extensions—preserved soft breaks, `<u>`, and `ticker-asset` width. Reject tables, task lists, strikethrough, and all other raw HTML before persistence.

No migration mapper, citation node, provenance mark, table nodes, task attributes, or third-party Markdown plugins.

## A. markdown-it configuration

Use `markdown-it` directly and declare it as a direct dependency because the codec configures it directly, even though `prosemirror-markdown` already brings it transitively.

Configuration:

- Preset: `commonmark`
- `html: true` — required solely to receive `<u>`/`</u>` as `html_inline`
- `breaks: false` — retain `softbreak` tokens; do not conflate them with hard breaks
- `linkify: false` — bare URLs remain text; only explicit Markdown links/autolinks become links
- `typographer: false` — no smart quotes, dash substitution, or content mutation
- Keep the remaining CommonMark rules unchanged
- Additionally enable `table` and `strikethrough`, but only as rejection sentinels
- No third-party plugins

Register two local rules directly:

1. `ticker_image_width`: inline rule before `text`; consumes a width suffix immediately following an image token.
2. One post-inline validation/normalization rule:
   - Converts valid `html_inline` `<u>` tokens into synthetic underline open/close tokens.
   - Rejects invalid/unmatched HTML.
   - Rejects table, strikethrough, and task-list tokens/patterns.

Serializer options:

- Strict mode on.
- Stock list behavior.
- `escapeExtraCharacters: /[<>{}|]/g`

Those extra escapes are necessary so literal user text such as `<u>`, table-looking pipes, or `{width=300}` cannot be reinterpreted as syntax on reload. Stock escaping already covers `~` and `[`.

## B. Nodes

Use the stock `prosemirror-markdown` 1.13.5 schema definitions unless overridden below.

| Name | Schema | Markdown token | Serializer |
|---|---|---|---|
| `doc` | `content: "block+"` | Root | Render children |
| `paragraph` | `content: "inline*"`, `group: "block"` | `paragraph_open/close` | `renderInline`, then `closeBlock` |
| `heading` | `level: 1` default, validate 1–6; `content: "(text \| image)*"`, `group: "block"`, `defining: true` | `heading_open/close`; level from tag | ATX form: `#` × level, space, inline content |
| `blockquote` | `content: "block+"`, `group: "block"` | `blockquote_open/close` | Stock `wrapBlock("> ")` |
| `code_block` | `params: ""` default; `content: "text*"`, `group: "block"`, `code: true`, `defining: true`, `marks: ""` | `code_block`, `fence`; `params = token.info` | Stock fenced serializer; choose a fence longer than backtick runs, preserve `params` |
| `horizontal_rule` | Leaf block; atomic by being a leaf | `hr` | Canonical `---` |
| `bullet_list` | `tight: false`; `content: "list_item+"`, `group: "block"` | `bullet_list_open/close` | Stock canonical `* ` markers |
| `ordered_list` | `order: 1`, `tight: false`; `content: "list_item+"`, `group: "block"` | `ordered_list_open/close` | Stock numbered-list serializer preserving start |
| `list_item` | `content: "block+"`, `defining: true` | `list_item_open/close` | Render block content |
| `image` | Required `src`; `alt: null`, `title: null`, `width: null`; `inline: true`, `group: "inline"`, `draggable: true`; leaf/atom implicitly | `image` | Stock image syntax, followed by `{width=N}` only when width is non-null |
| `hard_break` | `inline: true`, `group: "inline"`, `selectable: false`; leaf/atom implicitly | `hardbreak` | Stock `\\\n` form |
| `soft_break` | Same structural properties as `hard_break`; DOM form should distinguish it, e.g. `<br data-soft-break>` | `softbreak` | Emit a literal `\n` |
| `text` | `group: "inline"` | `text` | Stock escaped text serializer |

Image width rules:

- Type: `null` or integer.
- Valid range: 120–920.
- Only legal when `src` starts with `ticker-asset://`, including `ticker-asset:///`.
- Invalid or out-of-range widths throw during parsing; do not clamp external input silently.
- Image commands/resizing must write an already-rounded valid integer.
- Serializer throws if an invalid PM image somehow carries width or a non-asset image carries width.

Do not add image height, original dimensions, asset ID, citation data, heading IDs, paragraph attrs, or bullet-marker attrs.

## Marks

Schema order should be:

1. `underline`
2. `em`
3. `strong`
4. `link`
5. `code`

That keeps underline outermost and code innermost in canonical nesting.

| Name | Attrs/spec | Markdown token | Serializer |
|---|---|---|---|
| `underline` | No attrs; inclusive default | Synthetic `underline_open/close` | `<u>` / `</u>`; `mixable: true`, `expelEnclosingWhitespace: true` |
| `em` | Stock | `em_open/close` | `*`; stock mixable/whitespace behavior |
| `strong` | Stock | `strong_open/close` | `**`; stock mixable/whitespace behavior |
| `link` | Required `href`; `title: null`; `inclusive: false` | `link_open/close` | Stock link serializer |
| `code` | No attrs; `code: true` | `code_inline` | Stock dynamically sized backticks |

Links receive no Ticker-specific subtype. Preserve `href` and `title` as strings without URL normalization. `ticker-pdf://`, HTTP(S), relative links, and explicit CommonMark autolinks all use the same mark. The serializer may escape Markdown-sensitive parentheses, but reparsing must recover the exact attribute value.

## C. Rulings

### 1. Preserve soft breaks

A writing app must not turn an authored line break into a space. The loss cannot be repaired by serializer wrapping because the parser has already forgotten whether the space was typed or came from a newline.

Therefore:

- Map `softbreak` to a real `soft_break` inline node.
- Serialize it as one literal newline.
- Do not use `breaks: true`.
- Do not implement column-based rewrapping.
- Regular Return should create a new paragraph; Shift-Return should insert `soft_break`.
- Keep `hard_break` separately for imported explicit Markdown hard breaks.

### 2. Underline token mechanism

For each `inline` token independently:

1. Walk its child tokens.
2. Recognize only case-insensitive `<u\s*>` and `</u\s*>`, with no attributes.
3. Replace them with `underline_open` and `underline_close`.
4. Maintain one boolean open state.
5. Reject:
   - An unmatched close.
   - An unmatched open at the end of the inline token.
   - Nested `<u>`.
   - `<u>` tags with attributes.
   - Any other `html_inline` or `html_block`.

A soft break within the same paragraph may remain inside underline. A blank line creates another inline/block context, so `<u>` crossing paragraphs is rejected. Do not split it automatically.

The serializer always emits lowercase, attribute-free `<u>…</u>`.

### 3. Image width mechanism

Build a custom inline rule, not a post-PM fixup and not an external plugin.

The rule runs before Markdown-it’s `text` rule:

- At `{width=…}`, inspect the immediately preceding emitted token.
- It must be an image token.
- It must have a `ticker-asset://` source.
- Parse exact syntax `{width=N}` with no intervening whitespace.
- Validate integer 120–920.
- Store it in token metadata and consume the suffix without emitting text.
- `image.getAttrs` copies that metadata to `node.attrs.width`.

Why this layer:

- It reuses Markdown-it’s image grammar rather than duplicating it.
- It removes the suffix before it can become a PM text node.
- Unlike post-token fixup, it can distinguish an escaped literal `\{width=300\}` from the real attribute.
- It needs no dependency.

An immediate malformed width suffix after an image is a typed parse error. An escaped suffix remains literal text.

### 4. Reject tables, task lists, and strikethrough

Do not add them to this schema.

- Tables require four structural nodes, a serializer, editing commands, navigation behavior, and realistically `prosemirror-tables`.
- Task lists require semantic checked state and an interactive checkbox NodeView.
- Strikethrough is cheap alone, but it is not a Ticker feature and the generic rejection boundary is required anyway.

Mechanical rejection:

- Enable Markdown-it’s table and strikethrough rules.
- If the completed token stream contains `table_open` or `s_open`, throw `UnsupportedMarkdownError` with kind and source line.
- For task lists, inspect each list item’s first inline token’s raw `content`; reject an unescaped leading `[ ]`, `[x]`, or `[X]`.
- Throw before constructing or mutating a PM document.
- Return no partial document.

“Loud” means:

- The fragment is rejected before persistence and before editor insertion.
- The UI says exactly which construct was rejected.
- The original fragment remains copyable/retryable.
- Nothing is silently converted to text.

This imposes one non-schema requirement: the current persist-then-notify Swift append order cannot remain for arbitrary fragments. The Web codec must validate a proposed fragment before `appendToStreamDocument` commits it. A post-persistence toast is insufficient because it leaves the stored document unparsable.

Also add a prompt guard asking document-producing AI not to emit tables, task lists, strikethrough, or raw HTML. That reduces failures but is not the validator.

### 5. Other constraints

- Include `horizontal_rule`; it is stock CommonMark and AI can emit `---`.
- Reference links need no special schema. They canonicalize to ordinary links.
- PDF citations remain plain `link` marks.
- Provenance and margin notes remain external metadata, never PM marks/nodes.
- Buffer AI Markdown until the response is complete. Do not parse streaming chunks individually: an intermediate chunk may end halfway through a link, fence, or mark. Apply the completed parsed result as one transaction/undo step.
- Quick Capture, PDF AI, Quick Panel AI, and `ticker://append` must all use the same parser gate.
- On external append, parse the fragment standalone and insert its block nodes. Derive provenance from the final inserted PM range, then use the serializer map when saving.
- Literal user text resembling unsupported syntax must remain valid. The serializer’s added escaping for `<>{}|`, combined with stock escaping for `~` and `[`, guarantees its own output will not trip the rejection gate.

## D. Minimum proof

Use exact `doc.toJSON()` equality wherever possible. Six focused test groups are enough.

1. **Stock dialect fixture**

   One document containing H3, paragraph, blockquote, tight bullet list, ordered list starting at 3, fenced code with info, horizontal rule, image, hard break, em/strong/code/link.

   Assert exact tree order, heading level, list `tight`, ordered `order`, code `params`, and every mark occurrence. Assert one-pass canonical fixed point.

2. **Soft versus hard break**

   - `line one\nline two` must produce exactly `text`, `soft_break`, `text` and serialize identically.
   - An explicit hard break must produce `hard_break` and serialize to canonical backslash-newline syntax.
   - A soft break inside a blockquote must retain the quote on reparsing.

3. **Underline**

   For `<u>A **B**</u> and <u>C</u>` assert:

   - `A`, `B`, and `C` each carry underline.
   - Only `B` carries strong as well.
   - No text node contains `<u>` or `</u>`.
   - Serialization is the specified canonical nesting.
   - Unmatched open, unmatched close, nested underline, attributed `<u>`, and cross-paragraph underline each throw `InvalidMarkdownError("underline")`.

4. **Image width**

   For one asset image with title/width and one ordinary image, assert exact per-node attrs:

   - Exact `src`, `alt`, and `title`.
   - Asset width exactly `300`.
   - Ordinary image width exactly `null`.
   - No text node contains `{width=`.
   - Exact canonical serialization.
   - Escaped literal `\{width=300\}` remains text and does not set width.
   - Invalid range and non-asset width throw.

5. **Links and content preservation**

   Include two links: an escaped-label `ticker-pdf://` citation with `page`, `chunk`, and encoded `q`, plus HTTP with title.

   Assert each occurrence’s exact `href`, `title`, label text, and marks. Reparse serialized output and compare attributes again. Assert a bare URL remains unmarked and straight quotes/dashes remain byte-identical text.

6. **Rejection and serializer safety**

   Parameterize:

   - Table → `UnsupportedMarkdownError("table")`
   - Task item → `UnsupportedMarkdownError("task_list")`
   - Strikethrough → `UnsupportedMarkdownError("strikethrough")`
   - Other HTML → `UnsupportedMarkdownError("html")`

   Also construct PM text containing literal `<u>`, pipes shaped like a table, `~~text~~`, `[ ]`, and `{width=300}`. Serialize and reparse it, asserting exact text equality. This proves the serializer cannot emit content that its own parser rejects.

That is the complete schema. Cut everything else until a real product feature requires it.

No files were changed or committed.
