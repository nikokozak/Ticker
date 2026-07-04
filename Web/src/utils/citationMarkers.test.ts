import { describe, expect, it } from 'vitest';
import {
  buildProvenanceLine,
  sourceLabelFromCitationLabel,
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
    label: 'Manual p.12',
  },
  {
    n: 2,
    chunkId: 'chunk-2',
    sourceId: 'source-2',
    page: 8,
    label: 'Guide p.8',
  },
];

describe('swapCitationMarkers', () => {
  it('replaces a single marker with a ticker pdf markdown link', () => {
    expect(swapCitationMarkers('Use the stack carefully.【1】', citations)).toBe(
      'Use the stack carefully.[Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1)'
    );
  });

  it('replaces multiple markers', () => {
    expect(swapCitationMarkers('Both manuals agree.【1】 Later details differ.【2】', citations)).toBe(
      'Both manuals agree.[Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1) Later details differ.[Guide p.8](ticker-pdf://source-2?page=8&chunk=chunk-2)'
    );
  });

  it('replaces adjacent markers without adding spacing', () => {
    expect(swapCitationMarkers('Compare both.【1】【2】', citations)).toBe(
      'Compare both.[Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1)[Guide p.8](ticker-pdf://source-2?page=8&chunk=chunk-2)'
    );
  });

  it('drops an unknown marker silently', () => {
    expect(swapCitationMarkers('Known.【1】 Unknown.【99】', citations)).toBe(
      'Known.[Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1) Unknown.'
    );
  });

  it('handles a marker inside a sentence', () => {
    expect(swapCitationMarkers('The claim【1】 remains grammatical.', citations)).toBe(
      'The claim[Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1) remains grammatical.'
    );
  });

  it('leaves text without markers unchanged', () => {
    expect(swapCitationMarkers('No citations here.', citations)).toBe('No citations here.');
  });
});

describe('sourceLabelFromCitationLabel', () => {
  it('removes the citation page suffix', () => {
    expect(sourceLabelFromCitationLabel('Manual p.12')).toBe('Manual');
    expect(sourceLabelFromCitationLabel('Guide p. 8')).toBe('Guide');
  });
});

describe('buildProvenanceLine', () => {
  const swapped: SwappedCitation[] = [
    {
      n: 1,
      chunkId: 'chunk-1',
      sourceId: 'source-1',
      label: 'Manual p.12',
      sourceLabel: 'Manual',
    },
    {
      n: 2,
      chunkId: 'chunk-2',
      sourceId: 'source-2',
      label: 'Guide p.8',
      sourceLabel: 'Guide',
    },
    {
      n: 1,
      chunkId: 'chunk-1',
      sourceId: 'source-1',
      label: 'Manual p.12',
      sourceLabel: 'Manual',
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
      'Alpha[Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1) Beta[Guide p.8](ticker-pdf://source-2?page=8&chunk=chunk-2) Gamma[Manual p.12](ticker-pdf://source-1?page=12&chunk=chunk-1)'
    );
    expect(provenanceLine).toBe('*Consulted: Manual (2), Guide (1)*');
  });
});
