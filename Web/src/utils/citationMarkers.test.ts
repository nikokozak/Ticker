import { describe, expect, it } from 'vitest';
import {
  buildProvenanceLine,
  swapCitationMarkers,
  swapCitationMarkersWithMetadata,
  type SwappedCitation,
} from './citationMarkers';
import type { DocumentAICitation } from '../types';

const citations: DocumentAICitation[] = [
  {
    n: 1,
    chunkId: 'chunk-1',
    sourceId: 'source-1',
    page: 12,
    shortTitle: 'Manual',
  },
  {
    n: 2,
    chunkId: 'chunk-2',
    sourceId: 'source-2',
    page: 8,
    shortTitle: 'Guide',
  },
];

const singleSourceCitations: DocumentAICitation[] = [
  {
    n: 1,
    chunkId: 'chunk-1',
    sourceId: 'source-1',
    page: 12,
    shortTitle: 'Manual',
  },
  {
    n: 2,
    chunkId: 'chunk-2',
    sourceId: 'source-1',
    page: 13,
    shortTitle: 'Manual',
  },
];

describe('swapCitationMarkers', () => {
  it('replaces a single marker with a ticker pdf markdown link', () => {
    expect(swapCitationMarkers('Use the stack carefully.【1】', citations)).toBe(
      'Use the stack carefully. [Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1)'
    );
  });

  it('replaces multiple markers', () => {
    expect(swapCitationMarkers('Both manuals agree.【1】 Later details differ.【2】', citations)).toBe(
      'Both manuals agree. [Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1) Later details differ. [Guide p.8](ticker-pdf://source-2?page=8&chunk=chunk-2)'
    );
  });

  it('spaces adjacent different citations', () => {
    expect(swapCitationMarkers('Compare both.【1】【2】', citations)).toBe(
      'Compare both. [Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1) [Guide p.8](ticker-pdf://source-2?page=8&chunk=chunk-2)'
    );
  });

  it('drops an unknown marker silently', () => {
    expect(swapCitationMarkers('Known.【1】 Unknown.【99】', citations)).toBe(
      'Known. [Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1) Unknown.'
    );
  });

  it('handles a marker inside a sentence', () => {
    expect(swapCitationMarkers('The claim【1】 remains grammatical.', citations)).toBe(
      'The claim [Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1) remains grammatical.'
    );
  });

  it('leaves text without markers unchanged', () => {
    expect(swapCitationMarkers('No citations here.', citations)).toBe('No citations here.');
  });

  it('uses page-only labels when every citation is from one source', () => {
    expect(swapCitationMarkers('The page is enough.【1】', singleSourceCitations)).toBe(
      'The page is enough. [p.12](ticker-pdf://source-1?page=12&chunk=chunk-1)'
    );
  });

  it('uses source-prefixed labels when citations span multiple sources', () => {
    expect(swapCitationMarkers('Disambiguate this.【2】', citations)).toBe(
      'Disambiguate this. [Guide p.8](ticker-pdf://source-2?page=8&chunk=chunk-2)'
    );
  });

  it('escapes both brackets in source-prefixed labels', () => {
    const bracketed = { ...citations[1], shortTitle: 'Guide [draft]' };
    expect(swapCitationMarkers('Disambiguate this.【2】', [citations[0], bracketed])).toBe(
      'Disambiguate this. [Guide \\[draft\\] p.8](ticker-pdf://source-2?page=8&chunk=chunk-2)'
    );
  });

  it('inserts exactly one space before a swapped link', () => {
    expect(swapCitationMarkers('Crowded  【1】', citations)).toBe(
      'Crowded [Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1)'
    );
  });

  it('collapses adjacent duplicate citations for the same chunk', () => {
    const result = swapCitationMarkersWithMetadata('Repeat this.【1】  【1】', citations);

    expect(result.text).toBe(
      'Repeat this. [Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1)'
    );
    expect(result.swappedCitations).toHaveLength(1);
  });

  it('adds a quote query parameter for quoted markers', () => {
    expect(swapCitationMarkers('Evidence lands here.【1|"exact supporting words"】', citations)).toBe(
      'Evidence lands here. [Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1&q=exact%20supporting%20words)'
    );
  });

  it('accepts typographic quote delimiters', () => {
    expect(swapCitationMarkers('Curly quote marker.【1|“curly quoted span”】', citations)).toBe(
      'Curly quote marker. [Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1&q=curly%20quoted%20span)'
    );
  });

  it('accepts the observed provider closing-brace typo', () => {
    expect(swapCitationMarkers('Provider typo.【1|"exact supporting words"}', citations)).toBe(
      'Provider typo. [Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1&q=exact%20supporting%20words)'
    );
  });

  it('keeps braces inside a valid quoted marker', () => {
    expect(swapCitationMarkers('Code quote.【1|"pushes {x} onto the stack"】', citations)).toBe(
      'Code quote. [Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1&q=pushes%20%7Bx%7D%20onto%20the%20stack)'
    );
  });

  it('does not merge a typo marker with a later citation', () => {
    expect(
      swapCitationMarkers('First.【1|"alpha"} prose Second.【2|"beta"】', citations)
    ).toBe(
      'First. [Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1&q=alpha) prose Second. [Guide p.8](ticker-pdf://source-2?page=8&chunk=chunk-2&q=beta)'
    );
  });

  it('treats a malformed quoted marker as a plain marker', () => {
    expect(swapCitationMarkers('Malformed quote.【1|"missing close】', citations)).toBe(
      'Malformed quote. [Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1)'
    );
  });

  it('URL-encodes quote query parameters', () => {
    expect(swapCitationMarkers('Encoded quote.【1|"A & B / C"】', citations)).toBe(
      'Encoded quote. [Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1&q=A%20%26%20B%20%2F%20C)'
    );
  });
});

describe('buildProvenanceLine', () => {
  const swapped: SwappedCitation[] = [
    {
      n: 1,
      chunkId: 'chunk-1',
      sourceId: 'source-1',
      shortTitle: 'Manual',
    },
    {
      n: 2,
      chunkId: 'chunk-2',
      sourceId: 'source-2',
      shortTitle: 'Guide',
    },
    {
      n: 1,
      chunkId: 'chunk-1',
      sourceId: 'source-1',
      shortTitle: 'Manual',
    },
  ];

  it('builds a line for one source', () => {
    expect(buildProvenanceLine(swapped.slice(0, 1))).toBe('*Consulted: Manual (1)*');
  });

  it('orders two sources by swapped citation count', () => {
    expect(buildProvenanceLine(swapped)).toBe('*Consulted: Manual (2), Guide (1)*');
  });

  it('returns null when no citations were swapped', () => {
    expect(buildProvenanceLine([])).toBeNull();
  });
});

describe('swapCitationMarkersWithMetadata', () => {
  it('supports swap then provenance strip construction', () => {
    const result = swapCitationMarkersWithMetadata('Alpha【1】 Beta【2】 Gamma【1】', citations);
    const provenanceLine = buildProvenanceLine(result.swappedCitations);

    expect(result.text).toBe(
      'Alpha [Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1) Beta [Guide p.8](ticker-pdf://source-2?page=8&chunk=chunk-2) Gamma [Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1)'
    );
    expect(provenanceLine).toBe('*Consulted: Manual (2), Guide (1)*');
  });
});
