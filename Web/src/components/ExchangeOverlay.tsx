import type { AIExchangeJSON } from '../types';
import { XIcon } from './icons';
import { Modal } from './Modal';

export interface ExchangeManifestEntry {
  sourceId: string;
  chunkId: string;
  page: number;
  shortTitle: string;
}

interface ExchangeOverlayProps {
  exchange: AIExchangeJSON;
  onClose: () => void;
  onRedevelop?: () => void;
  onOpenManifestEntry: (entry: ExchangeManifestEntry) => void;
}

function manifestEntries(sourceManifest: string): ExchangeManifestEntry[] {
  try {
    const parsed = JSON.parse(sourceManifest) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.flatMap((item): ExchangeManifestEntry[] => {
      if (!item || typeof item !== 'object') return [];
      const candidate = item as Record<string, unknown>;
      const sourceId = typeof candidate.sourceId === 'string' ? candidate.sourceId : '';
      const chunkId = typeof candidate.chunkId === 'string' ? candidate.chunkId : '';
      const shortTitle = typeof candidate.shortTitle === 'string' ? candidate.shortTitle : '';
      const page = Number(candidate.page);
      if (!sourceId || !chunkId || !shortTitle || !Number.isFinite(page)) return [];
      return [{ sourceId, chunkId, shortTitle, page: Math.max(1, Math.round(page)) }];
    });
  } catch {
    return [];
  }
}

export function ExchangeOverlay({
  exchange,
  onClose,
  onRedevelop,
  onOpenManifestEntry,
}: ExchangeOverlayProps) {
  const entries = manifestEntries(exchange.sourceManifest);

  const copyRaw = () => {
    void navigator.clipboard?.writeText(exchange.responseRaw);
  };

  return (
    <Modal
      className="exchange-modal"
      aria-labelledby="exchange-modal-title"
      onRequestClose={onClose}
    >
        <div className="exchange-modal-header">
          <h2 id="exchange-modal-title">Exchange</h2>
          <button
            type="button"
            className="exchange-modal-close"
            onClick={onClose}
            aria-label="Close"
          >
            <XIcon size={16} />
          </button>
        </div>

        <div className="exchange-block">
          <h2>You</h2>
          <pre>{exchange.userInput}</pre>
        </div>

        <div className="exchange-block">
          <h2>Consulted</h2>
          {entries.length > 0 ? (
            <div className="exchange-manifest-links">
              {entries.map((entry) => (
                <button
                  key={`${entry.sourceId}:${entry.chunkId}:${entry.page}`}
                  type="button"
                  className="exchange-link"
                  onClick={() => onOpenManifestEntry(entry)}
                >
                  {entry.shortTitle} p.{entry.page}
                </button>
              ))}
            </div>
          ) : (
            <p>No sources recorded.</p>
          )}
        </div>

        <div className="exchange-block">
          <h2>Model returned</h2>
          <pre>{exchange.responseRaw}</pre>
        </div>

        <div className="exchange-footer">
          {onRedevelop && <button type="button" onClick={onRedevelop}>re-develop</button>}
          <button type="button" onClick={copyRaw}>copy raw</button>
        </div>
    </Modal>
  );
}
