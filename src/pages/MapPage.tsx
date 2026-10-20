import { useMemo, useState } from 'react';
import { useStore } from '../app/store';
import { Card, PersonLink } from '../components/common';
import { dateLabel } from '../genealogy/gedcom/dates';
import type { ID } from '../database/types';

const TYPES: Record<string, string> = { BIRT: 'Birth', DEAT: 'Death', RESI: 'Residence', MARR: 'Marriage', EMIG: 'Emigration', IMMI: 'Immigration', BURI: 'Burial', CENS: 'Census' };

/**
 * Plots only coordinates recorded in the data (GEDCOM PLAC.MAP). No geocoding guesses.
 * Places without coordinates are listed so they can be researched.
 */
export default function MapPage() {
  const { persons, families, graph, workspace, select } = useStore();
  const [year, setYear] = useState<number>();
  const [gen, setGen] = useState(0);
  const [types, setTypes] = useState(new Set(Object.keys(TYPES)));
  const scope = useMemo(() => {
    if (!gen || !workspace?.rootPersonId) return undefined;
    return new Set([workspace.rootPersonId, ...[...graph.ancestors(workspace.rootPersonId, { maxDepth: gen })].map((x) => x[0])]);
  }, [gen, graph, workspace?.rootPersonId]);
  const events = useMemo(() => {
    const out: { personId: ID; type: string; place: string; lat?: number; lon?: number; year?: number; label: string }[] = [];
    for (const p of persons) {
      if (scope && !scope.has(p.id)) continue;
      for (const e of p.events) if (e.place && types.has(e.type)) out.push({ personId: p.id, type: e.type, place: e.place, lat: e.lat, lon: e.lon, year: e.date?.sortYear, label: dateLabel(e.date) });
    }
    for (const f of families) for (const e of f.events) if (e.place && types.has(e.type) && f.partnerIds[0] && (!scope || f.partnerIds.some((x) => scope.has(x)))) out.push({ personId: f.partnerIds[0], type: e.type, place: e.place, lat: e.lat, lon: e.lon, year: e.date?.sortYear, label: dateLabel(e.date) });
    return out;
  }, [persons, families, types, scope]);
  const years = events.map((e) => e.year).filter((y): y is number => y !== undefined);
  const minY = Math.min(...years), maxY = Math.max(...years);
  const shown = events.filter((e) => year === undefined || (e.year !== undefined && e.year <= year));
  const plotted = shown.filter((e) => e.lat !== undefined && e.lon !== undefined);
  const clusters = new Map<string, typeof plotted>();
  for (const e of plotted) { const k = `${Math.round(e.lat! * 2) / 2},${Math.round(e.lon! * 2) / 2}`; (clusters.get(k) ?? clusters.set(k, []).get(k)!).push(e); }
  const places = new Map<string, number>();
  for (const e of shown.filter((x) => x.lat === undefined)) places.set(e.place, (places.get(e.place) ?? 0) + 1);
  const W = 1000, H = 500, px = (lon: number) => ((lon + 180) / 360) * W, py = (lat: number) => ((90 - lat) / 180) * H;
  // Migration lines: consecutive dated, located events per person.
  const moves = new Map<ID, typeof plotted>();
  for (const e of plotted.filter((x) => x.year !== undefined)) (moves.get(e.personId) ?? moves.set(e.personId, []).get(e.personId)!).push(e);
  return (
    <div className="space-y-4">
      <Card>
        <div className="grid gap-3 md:grid-cols-3">
          <label className="text-sm">Up to year: <b>{year ?? 'all'}</b>{years.length > 0 && <input type="range" min={minY} max={maxY} value={year ?? maxY} onChange={(e) => setYear(+e.target.value)} className="block w-full accent-emerald-500" />}</label>
          <label className="text-sm">Generations from home person<select className="input mt-1" value={gen} onChange={(e) => setGen(+e.target.value)}><option value={0}>Everyone</option>{[1, 2, 3, 4, 5, 6, 8, 10].map((g) => <option key={g} value={g}>{g}</option>)}</select></label>
          <div className="flex flex-wrap gap-2 text-xs">{Object.entries(TYPES).map(([k, v]) => <label key={k} className="chip gap-1"><input type="checkbox" checked={types.has(k)} onChange={(e) => { const n = new Set(types); e.target.checked ? n.add(k) : n.delete(k); setTypes(n); }} />{v}</label>)}</div>
        </div>
      </Card>
      <Card title={`Located events (${plotted.length})`}>
        <div className="overflow-auto">
          <svg viewBox={`0 0 ${W} ${H}`} className="w-full panel-2" role="img" aria-label="World map of recorded event coordinates">
            {Array.from({ length: 11 }, (_, i) => <line key={'v' + i} x1={(i * W) / 12 + W / 12} x2={(i * W) / 12 + W / 12} y1={0} y2={H} stroke="var(--border)" strokeWidth={0.5} />)}
            {Array.from({ length: 5 }, (_, i) => <line key={'h' + i} y1={(i * H) / 6 + H / 6} y2={(i * H) / 6 + H / 6} x1={0} x2={W} stroke="var(--border)" strokeWidth={i === 2 ? 1 : 0.5} />)}
            {[...moves.values()].map((evs, i) => { const s = evs.sort((x, y) => x.year! - y.year!); return s.length > 1 ? <polyline key={i} points={s.map((e) => `${px(e.lon!)},${py(e.lat!)}`).join(' ')} fill="none" stroke="#e5c062" strokeWidth={1} opacity={0.6} /> : null; })}
            {[...clusters.entries()].map(([k, evs]) => <g key={k} onClick={() => select(evs[0].personId)} style={{ cursor: 'pointer' }}><circle cx={px(evs[0].lon!)} cy={py(evs[0].lat!)} r={4 + Math.min(10, evs.length)} fill="#10b981" opacity={0.75}><title>{evs.map((e) => `${TYPES[e.type]} ${e.label} ${e.place}`).join('\n')}</title></circle></g>)}
          </svg>
        </div>
        <p className="mt-2 text-xs muted">Graticule projection without a basemap (offline). Only coordinates present in your records are plotted; gold lines connect one person’s dated locations. A MapLibre basemap is planned for a later version.</p>
      </Card>
      <Card title={`Places without coordinates (${places.size})`}>
        <ul className="grid gap-1 text-sm sm:grid-cols-2">{[...places].sort((a, b) => b[1] - a[1]).slice(0, 100).map(([p, n]) => <li key={p}>{p} <span className="muted">· {n} event(s)</span></li>)}</ul>
        {plotted.length > 0 && <div className="mt-3 text-sm"><div className="label">Plotted</div>{plotted.slice(0, 30).map((e, i) => <div key={i}><PersonLink id={e.personId} showYears={false} /> — {TYPES[e.type]} {e.label} at {e.place}</div>)}</div>}
      </Card>
    </div>
  );
}
