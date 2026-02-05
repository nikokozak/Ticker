export const IS_DEV = Boolean((import.meta as any).env?.DEV);

export function debugLog(...args: unknown[]) {
  if (!IS_DEV) return;
  // eslint-disable-next-line no-console
  console.log(...args);
}

export function debugWarn(...args: unknown[]) {
  if (!IS_DEV) return;
  // eslint-disable-next-line no-console
  console.warn(...args);
}

export function debugError(...args: unknown[]) {
  if (!IS_DEV) return;
  // eslint-disable-next-line no-console
  console.error(...args);
}
