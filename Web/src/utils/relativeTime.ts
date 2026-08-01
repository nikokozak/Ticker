export function formatRelativeTime(dateString: string): string {
  const age = Date.now() - new Date(dateString).getTime();
  const minutes = Math.floor(age / 60_000);
  const hours = Math.floor(age / 3_600_000);
  const days = Math.floor(age / 86_400_000);
  if (minutes < 1) return 'just now';
  if (minutes < 60) return `${minutes}m ago`;
  if (hours < 24) return `${hours}h ago`;
  if (days < 30) return `${days}d ago`;
  if (days < 365) return `${Math.floor(days / 30)}mo ago`;
  return `${Math.floor(days / 365)}y ago`;
}
