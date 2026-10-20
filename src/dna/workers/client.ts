import type { DnaWorkerRequest } from './dnaWorker';

/** Run a DNA job in a Web Worker so parsing 600k+ rows never blocks the UI. */
export function runDnaJob<T>(req: DnaWorkerRequest): Promise<T> {
  return new Promise((resolve, reject) => {
    const w = new Worker(new URL('./dnaWorker.ts', import.meta.url), { type: 'module' });
    w.onmessage = (e) => { w.terminate(); e.data.ok ? resolve(e.data.result as T) : reject(new Error(e.data.error)); };
    w.onerror = (e) => { w.terminate(); reject(new Error(e.message)); };
    w.postMessage(req, req.kind === 'parse' ? [req.bytes] : []);
  });
}
