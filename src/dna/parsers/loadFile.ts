import { isZip, readZip } from '../../exports/zip';
import { NotGenotypeFileError, parseGenotypeText, type ParsedKit } from './genotype';

/** Accept raw .txt/.csv or a ZIP containing one; rejects PDFs and images. */
export async function loadGenotypeBytes(fileName: string, bytes: Uint8Array): Promise<ParsedKit & { innerFile?: string }> {
  if (/\.(pdf|png|jpe?g|gif|heic|webp)$/i.test(fileName)) throw new NotGenotypeFileError('Reports, PDFs and screenshots are not raw genotype data.');
  if (isZip(bytes)) {
    const entries = await readZip(bytes);
    const txt = entries.find((e) => /\.(txt|csv|tsv)$/i.test(e.name) && !/readme/i.test(e.name));
    if (!txt) throw new NotGenotypeFileError('The ZIP does not contain a raw genotype .txt file.');
    return { ...parseGenotypeText(new TextDecoder().decode(txt.data)), innerFile: txt.name };
  }
  return parseGenotypeText(new TextDecoder().decode(bytes));
}
