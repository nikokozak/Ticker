const markdownLinkPattern = /\[([^\]]+)]\(([^)]+)\)/g;
const markdownImagePattern = /!\[[^\]]*]\([^)]+\)/g;

export function plainTextFromMarkdown(line: string): string {
  return line
    .replace(/<\/?[A-Za-z][^>]*>/g, '')
    .replace(markdownImagePattern, '')
    .replace(markdownLinkPattern, '$1')
    .replace(/^>\s*/, '')
    .replace(/^[-*+]\s+/, '')
    .replace(/^\d+[.)]\s+/, '')
    .replace(/^#{1,6}\s+/, '')
    .replace(/`([^`]+)`/g, '$1')
    .replace(/(\*\*|__)(.*?)\1/g, '$2')
    .replace(/(\*|_)(.*?)\1/g, '$2')
    .replace(/[~*_#]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

export function markdownPreviewLine(markdown: string): string {
  for (const rawLine of markdown.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || /^#{1,6}\s+/.test(line) || /^!\[[^\]]*]\([^)]+\)\s*$/.test(line)) {
      continue;
    }

    const stripped = plainTextFromMarkdown(line);
    if (stripped) return stripped;
  }

  return '';
}
