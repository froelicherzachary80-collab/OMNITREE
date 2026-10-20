import { useMemo, useState, type ReactNode } from 'react';
import { displayName, eventOf, type ID, type Person } from '../database/types';
import { useStore } from '../app/store';
import { navigate } from '../app/router';

export function lifespan(p?: Person) {
  if (!p) return '';
  const b = eventOf(p, 'BIRT')?.date?.sortYear, d = eventOf(p, 'DEAT')?.date?.sortYear;
  return b || d ? `${b ?? '?'}–${d ?? ''}` : '';
}

export function Card({ title, children, actions, className = '' }: { title?: ReactNode; children: ReactNode; actions?: ReactNode; className?: string }) {
  return (
    <section className={`panel p-4 ${className}`}>
      {(title || actions) && (
        <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
          {title && <h2 className="text-lg font-semibold">{title}</h2>}
          {actions && <div className="flex flex-wrap gap-2">{actions}</div>}
        </div>
      )}
      {children}
    </section>
  );
}

export function Stat({ label, value, hint, onClick }: { label: string; value: ReactNode; hint?: string; onClick?: () => void }) {
  const Tag = onClick ? 'button' : 'div';
  return (
    <Tag onClick={onClick} className="panel p-4 text-left w-full hover:border-emerald-500 transition">
      <div className="label">{label}</div>
      <div className="mt-1 text-2xl font-semibold gold">{value}</div>
      {hint && <div className="mt-1 text-xs muted">{hint}</div>}
    </Tag>
  );
}

export function Empty({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <div className="panel-2 p-6 text-center">
      <div className="text-3xl" aria-hidden>🌳</div>
      <div className="mt-2 font-semibold">{title}</div>
      {children && <div className="mt-2 text-sm muted">{children}</div>}
    </div>
  );
}

export function PersonLink({ id, showYears = true }: { id: ID; showYears?: boolean }) {
  const { graph, select } = useStore();
  const p = graph.persons.get(id);
  if (!p) return <span className="muted">{id}</span>;
  return (
    <button className="link text-left" onClick={() => { select(id); navigate('tree'); }}>
      {displayName(p)}{showYears && lifespan(p) ? <span className="muted"> ({lifespan(p)})</span> : null}
    </button>
  );
}

/** Searchable person selector; never auto-picks among same-name people. */
export function PersonPicker({ value, onChange, label, placeholder = 'Search people…', testId }: { value?: ID; onChange: (id?: ID) => void; label?: string; placeholder?: string; testId?: string }) {
  const { persons, graph } = useStore();
  const [q, setQ] = useState('');
  const [open, setOpen] = useState(false);
  const results = useMemo(() => {
    const t = q.trim().toLowerCase();
    if (!t) return [];
    return persons.filter((p) => p.names.some((n) => n.full.toLowerCase().includes(t))).slice(0, 25);
  }, [q, persons]);
  const current = value ? graph.persons.get(value) : undefined;
  return (
    <div className="relative">
      {label && <div className="label mb-1">{label}</div>}
      <input
        data-testid={testId}
        className="input" value={open ? q : current ? `${displayName(current)} ${lifespan(current)}` : q}
        placeholder={placeholder} aria-label={label ?? placeholder}
        onFocus={() => { setOpen(true); setQ(''); }} onBlur={() => setTimeout(() => setOpen(false), 150)}
        onChange={(e) => setQ(e.target.value)}
      />
      {open && results.length > 0 && (
        <ul className="panel absolute z-30 mt-1 max-h-72 w-full overflow-auto p-1" role="listbox">
          {results.map((p) => (
            <li key={p.id}>
              <button role="option" aria-selected={p.id === value} className="w-full rounded-lg px-3 py-2 text-left hover:bg-emerald-500/10" onMouseDown={() => { onChange(p.id); setOpen(false); }}>
                <div className="font-medium">{displayName(p)} <span className="muted text-sm">{lifespan(p)}</span></div>
                <div className="text-xs muted">{eventOf(p, 'BIRT')?.place ?? ''} · {p.gedcomId ?? p.id}</div>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export function BasisChip({ basis }: { basis: 'documented' | 'inferred' | 'missing' | 'hypothetical' }) {
  const cls = basis === 'documented' ? 'chip-doc' : basis === 'missing' ? 'chip-miss' : 'chip-inf';
  const text = basis === 'documented' ? 'Documented' : basis === 'inferred' ? 'Inferred' : basis === 'missing' ? 'Evidence missing' : 'Hypothetical';
  return <span className={`chip ${cls}`}>{text}</span>;
}

export function download(name: string, data: BlobPart, type = 'application/octet-stream') {
  const url = URL.createObjectURL(new Blob([data], { type }));
  const a = document.createElement('a');
  a.href = url; a.download = name; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function Progress({ value, label }: { value?: number; label?: string }) {
  return (
    <div role="progressbar" aria-valuenow={value} aria-label={label} className="h-2 w-full overflow-hidden rounded-full bg-black/20">
      <div className={`h-full bg-emerald-500 ${value === undefined ? 'animate-pulse w-1/2' : ''}`} style={value !== undefined ? { width: `${value}%` } : undefined} />
    </div>
  );
}
