/// <reference lib="webworker" />
import { compareKits, ibsSummary, type KitInfo } from '../comparisons/compare';
import { loadGenotypeBytes } from '../parsers/loadFile';

export type DnaWorkerRequest =
  | { kind: 'parse'; fileName: string; bytes: ArrayBuffer }
  | { kind: 'compare'; a: KitInfo; b: KitInfo }
  | { kind: 'ibs'; a: KitInfo; b: KitInfo };

self.onmessage = async (e: MessageEvent<DnaWorkerRequest>) => {
  try {
    const m = e.data;
    if (m.kind === 'parse') self.postMessage({ ok: true, result: await loadGenotypeBytes(m.fileName, new Uint8Array(m.bytes)) });
    else if (m.kind === 'compare') self.postMessage({ ok: true, result: compareKits(m.a, m.b) });
    else self.postMessage({ ok: true, result: ibsSummary(m.a.variants, m.b.variants) });
  } catch (err) {
    self.postMessage({ ok: false, error: err instanceof Error ? err.message : String(err) });
  }
};
