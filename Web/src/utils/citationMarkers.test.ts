import { describe, expect, it } from 'vitest';
import { swapCitationMarkers } from './citationMarkers';
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
