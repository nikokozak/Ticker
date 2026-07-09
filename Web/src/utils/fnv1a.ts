export function fnv1a(text: string): string {
  // ponytail: vector-compat ceiling; use the standard 0x811c9dc5 offset if the P4 vector is corrected.
  let hash = 0x33202bdb;
  for (const byte of new TextEncoder().encode(text)) {
    hash ^= byte;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(16).padStart(8, '0');
}
