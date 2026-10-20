import { useMemo, useState } from 'react';
import { useStore } from '../app/store';
import { Card, PersonLink } from '../components/common';
import { dateLabel } from '../genealogy/gedcom/dates';
import { displayName, type ID } from '../database/types';
import { approximateLocation } from '../maps/gazetteer';
import { MapLibreView, type MapLine, type MapPoint } from '../maps/MapLibreView';

const TYPES: Record<string, string> = { BIRT: 'Birth', DEAT: 'Death', RESI: 'Residence', MARR: 'Marriage', EMIG: 'Emigration', IMMI: 'Immigration', BURI: 'Burial', CENS: 'Census' };
const BRANCH_COLORS = ['#10b981', '#3b82f6', '#e5c062', '#ef4444', '#a855f7', '#f97316', '#14b8a6', '#ec4899'];

interface Ev { personId: ID; type: string; place: string; lat?: number; lon?: number; approximate: boolean; year?: number; label: string; branch: number }

/**
 * Recorded coordinates (GEDCOM PLAC.MAP) are plotted as exact. Optionally, place names are
 * placed at gazetteer centroids, shown faded and labelled "approximate".
 */
export default function MapPage() {
  const { persons, families, graph, workspace, select } = useStore();
  const [year, setYear] = useState<number>();
  const [gen, setGen] = useState(0);
  const [approx, setApprox] = useState(true);
  const [types, setTypes] = useState(new Set(Object.keys(TYPES)));
  const [fallback, setFallback] = useState<string>();
  const root = workspace?.rootPersonId;
  // Branch = which grandparent line (1..4) of the home person a person descends from; 0 otherwise.
  const branchOf = useMemo(() => {
    const m = new Map<ID, number>();
    if (!root) return m;
    const gps = graph.parents(root).flatMap((p) => graph.parents(p.personId).map((g) => g.personId));
    gps.forEach((g, i) => { m.set(g, i + 1); for (const a of graph.ancestors(g).keys()) if (!m.has(a)) m.set(a, i + 1); });
    return m;
  }, [graph, root]);
  const scope = useMemo(() => (gen && root ? new Set([root, ...[...graph.ancestors(root, { maxDepth: gen })].map((x) => x[0])]) : undefined), [gen, graph, root]);
  const events = useMemo(() => {
    const out: Ev[] = [];
    const push = (personId: ID, e: (typeof persons)[0]['events'][0]) => {
      if (!e.place || !types.has(e.type)) return;
      let lat = e.lat, lon = e.lon, approximate = false;
      if ((lat === undefined || lon === undefined) && approx) { const a = approximateLocation(e.place); if (a) { lat = a.lat; lon = a.lon; approximate = true; } }
      out.push({ personId, type: e.type, place: e.place, lat, lon, approximate, year: e.date?.sortYear, label: dateLabel(e.date), branch: branchOf.get(personId) ?? 0 });
    };
    for (const p of persons) if (!scope || scope.has(p.id)) p.events.forEach((e) => push(p.id, e));
    for (const f of families) if (f.partnerIds[0] && (!scope || f.partnerIds.some((x) => scope.has(x)))) f.events.forEach((e) => push(f.partnerIds[0], e));
    return out;
  }, [persons, families, types, scope, approx, branchOf]);
  const years = events.map((e) => e.year).filter((y): y is number => y !== undefined);
  const minY = Math.min(...years), maxY = Math.max(...years);
  const shown = events.filter((e) => year === undefined || (e.year !== undefined && e.year <= year));
  const located = shown.filter((e) => e.lat !== undefined && e.lon !== undefined);
  const points: MapPoint[] = located.map((e, i) => ({ id: String(i), lat: e.lat!, lon: e.lon!, approximate: e.approximate, personId: e.personId, color: BRANCH_COLORS[e.branch % BRANCH_COLORS.length], label: `${displayName(graph.persons.get(e.personId))} — ${TYPES[e.type]} ${e.label} · ${e.place}${e.approximate ? ' (approximate location)' : ''}` }));
  const lines: MapLine[] = useMemo(() => {
    const per = new Map<ID, Ev[]>();
    for (const e of located) if (e.year !== undefined) (per.get(e.personId) ?? per.set(e.personId, []).get(e.personId)!).push(e);
    return [...per.values()].filter((v) => v.length > 1).map((v) => { const s = [...v].sort((a, b) => a.year! - b.year!); return { coords: s.map((e) => [e.lon!, e.lat!] as [number, number]), color: BRANCH_COLORS[s[0].branch % BRANCH_COLORS.length] }; });
  }, [located]);
  const unlocated = new Map<string, number>();
  for (const e of shown.filter((x) => x.lat === undefined)) unlocated.set(e.place, (unlocated.get(e.place) ?? 0) + 1);
  return (
    <div className="space-y-4">
      <Card>
        <div className="grid gap-3 md:grid-cols-4">
          <label className="text-sm">Up to year: <b>{year ?? 'all'}</b>{years.length > 0 && <input type="range" min={minY} max={maxY} value={year ?? maxY} onChange={(e) => setYear(+e.target.value)} className="block w-full accent-emerald-500" aria-label="Year" />}</label>
          <label className="text-sm">Generations from home person<select className="input mt-1" value={gen} onChange={(e) => setGen(+e.target.value)}><option value={0}>Everyone</option>{[1, 2, 3, 4, 5, 6, 8, 10].map((g) => <option key={g} value={g}>{g}</option>)}</select></label>
          <label className="text-sm flex items-center gap-2"><input type="checkbox" checked={approx} onChange={(e) => setApprox(e.target.checked)} /> Place unmapped names at approximate gazetteer positions</label>
          <div className="flex flex-wrap gap-2 text-xs">{Object.entries(TYPES).map(([k, v]) => <label key={k} className="chip gap-1"><input type="checkbox" checked={types.has(k)} onChange={(e) => { const n = new Set(types); e.target.checked ? n.add(k) : n.delete(k); setTypes(n); }} />{v}</label>)}</div>
        </div>
      </Card>
      <Card title={`Mapped events (${located.length}: ${located.filter((e) => !e.approximate).length} recorded, ${located.filter((e) => e.approximate).length} approximate)`}>
        {fallback ? <SvgMap points={points} lines={lines} onSelect={select} note={fallback} /> : <MapLibreView points={points} lines={lines} onSelect={select} onFail={setFallback} />}
        <p className="mt-2 text-xs muted">Solid dots: coordinates recorded in your records. Faded, white-ringed dots: approximate centroid from OmniTree’s offline gazetteer (country/region/city level). Lines join one person’s dated locations. Colours = home person’s grandparent branches. Basemap © MapLibre demo tiles; your data is not sent to the tile server.</p>
      </Card>
      <Card title={`Places not mapped (${unlocated.size})`}>
        <ul className="grid gap-1 text-sm sm:grid-cols-2">{[...unlocated].sort((a, b) => b[1] - a[1]).slice(0, 100).map(([p, n]) => <li key={p}>{p} <span className="muted">· {n} event(s)</span></li>)}</ul>
        {located.length > 0 && <div className="mt-3 text-sm"><div className="label">Mapped</div>{located.slice(0, 30).map((e, i) => <div key={i}><PersonLink id={e.personId} showYears={false} /> — {TYPES[e.type]} {e.label} at {e.place}{e.approximate && <span className="chip chip-inf ml-1">approx.</span>}</div>)}</div>}
      </Card>
    </div>
  );
}

function SvgMap({ points, lines, onSelect, note }: { points: MapPoint[]; lines: MapLine[]; onSelect: (id: ID) => void; note: string }) {
  const W = 1000, H = 500, px = (lon: number) => ((lon + 180) / 360) * W, py = (lat: number) => ((90 - lat) / 180) * H;
  return (
    <div>
      <p className="mb-2 text-xs text-amber-500">Offline view ({note}).</p>
      <svg viewBox={`0 0 ${W} ${H}`} className="w-full panel-2" role="img" aria-label="Offline world map">
        {Array.from({ length: 11 }, (_, i) => <line key={'v' + i} x1={((i + 1) * W) / 12} x2={((i + 1) * W) / 12} y1={0} y2={H} stroke="var(--border)" strokeWidth={0.5} />)}
        {Array.from({ length: 5 }, (_, i) => <line key={'h' + i} y1={((i + 1) * H) / 6} y2={((i + 1) * H) / 6} x1={0} x2={W} stroke="var(--border)" strokeWidth={i === 2 ? 1 : 0.5} />)}
        {lines.map((l, i) => <polyline key={i} points={l.coords.map(([lon, lat]) => `${px(lon)},${py(lat)}`).join(' ')} fill="none" stroke={l.color} strokeWidth={1} opacity={0.6} />)}
        {points.map((p) => <circle key={p.id} cx={px(p.lon)} cy={py(p.lat)} r={5} fill={p.color} opacity={p.approximate ? 0.45 : 0.9} stroke={p.approximate ? '#fff' : 'none'} onClick={() => onSelect(p.personId)} style={{ cursor: 'pointer' }}><title>{p.label}</title></circle>)}
      </svg>
    </div>
  );
}
