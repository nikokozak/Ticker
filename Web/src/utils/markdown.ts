import { marked } from 'marked';
import DOMPurify from 'dompurify';

// Configure marked for our use case
marked.setOptions({
  breaks: true, // Convert \n to <br>
  gfm: true, // GitHub Flavored Markdown
});

// Configure DOMPurify with allowed tags for markdown content
const SANITIZE_CONFIG = {
  ALLOWED_TAGS: [
    'p', 'br', 'strong', 'b', 'em', 'i', 'code', 'pre',
    'ul', 'ol', 'li',
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'blockquote', 'a', 'img',
    'table', 'thead', 'tbody', 'tr', 'th', 'td',
    'hr', 'del', 's', 'sup', 'sub',
  ],
  ALLOWED_ATTR: ['href', 'src', 'alt', 'class', 'title', 'target'],
  ALLOW_DATA_ATTR: false,
};

function isAllowedImageSrc(src: string): boolean {
  const trimmed = src.trim();
  if (!trimmed) return false;
  return (
    trimmed.startsWith('ticker-asset://') ||
    // Allow inline images (no network). Restrict to image media types.
    trimmed.startsWith('data:image/')
  );
}

function stripDisallowedImages(html: string): string {
  if (!html.includes('<img')) return html;

  // Prefer a DOM-based scrub so we handle weird quoting/spacing safely.
  // Fallback to a conservative regex strip if DOM APIs aren't available.
  try {
    if (typeof DOMParser === 'undefined') {
      return html.replace(/<img\b[^>]*>/gi, '');
    }

    const doc = new DOMParser().parseFromString(html, 'text/html');
    const images = Array.from(doc.querySelectorAll('img'));
    for (const img of images) {
      const src = img.getAttribute('src') ?? '';
      if (!isAllowedImageSrc(src)) {
        img.remove();
      }
    }
    return doc.body.innerHTML;
  } catch {
    return html.replace(/<img\b[^>]*>/gi, '');
  }
}

export function markdownToHtml(markdown: string): string {
  // Handle empty content
  if (!markdown.trim()) {
    return '<p></p>';
  }

  const html = marked.parse(markdown, { async: false }) as string;

  // Sanitize to prevent XSS from LLM output
  const sanitized = DOMPurify.sanitize(html, SANITIZE_CONFIG);

  // Prevent LLM output from embedding external <img> loads (privacy + unexpected network traffic).
  const noExternalImgs = stripDisallowedImages(sanitized);

  // Fix empty list items that cause TipTap/ProseMirror schema errors.
  // When streaming markdown, partial lists like "-" produce <li></li> which
  // violates ProseMirror's listItem content rules.
  // Insert a <br> placeholder to satisfy the schema.
  const fixedHtml = noExternalImgs.replace(/<li><\/li>/g, '<li><br></li>');

  return fixedHtml;
}
