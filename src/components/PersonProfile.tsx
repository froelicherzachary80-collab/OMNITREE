import { useEffect, useState } from 'react';
import { useStore } from '../app/store';
import { deletePerson } from '../database/repo';
import { displayName, eventOf, newId, type ChildRelation, type Family, type LifeEvent, type Person } from '../database/types';
import { dateLabel, parseGedDate } from '../genealogy/gedcom/dates';
import { linkEvidence } from '../ai/tools/genealogyTools';
import { BasisChip, PersonLink, PersonPicker } from './common';

function setEvent(p: Person, type: string, date: string, place: string): LifeEvent[] {
  const existing = eventOf(p, type);
  const rest = p.events.filter((e) => e !== existing);
  if (!date.trim() && !place.trim()) return existing && existing.citations.length ? [...rest, { ...existing, date: undefined, place: undefined }] : rest;
  return [...rest, { id: existing?.id ?? newId('ev'), type, date: date.trim() ? parseGedDate(date) : undefined, place: place.trim() || undefined, citations: existing?.citations ?? [] }];
}

export function blankPerson(workspaceId: string, given = '', surname = '', sex?: Person['sex']): Person {
  return { id: newId('indi'), workspaceId, names: [{ given, surname, full: `${given} ${surname}`.trim() }], sex, events: [], notes: [], mediaIds: [], dnaKitIds: [], privacy: 'private', extensions: [], associations: [], updatedAt: Date.now() };
}

export function PersonProfile({ person }: { person: Person }) {
  const store = useStore();
  const { graph, sources, workspace } = store;
  const [editing, setEditing] = useState(false);
  const [f, setF] = useState(() => formOf(person));
  const [relMode, setRelMode] = useState<'' | 'parent' | 'child' | 'partner'>('');
  useEffect(() => { setF(formOf(person)); setEditing(false); setRelMode(''); }, [person]);

  const save = async () => {
    const next: Person = {
      ...person,
      names: [{ ...person.names[0], given: f.given.trim(), surname: f.surname.trim(), full: `${f.given} ${f.surname}`.trim() }, ...person.names.slice(1)],
      sex: (f.sex || undefined) as Person['sex'], privacy: f.privacy as Person['privacy'], biography: f.bio || undefined, researchNotes: f.notes || undefined,
      historical: f.historical, traditional: f.traditional,
    };
    next.events = setEvent(next, 'BIRT', f.bdate, f.bplace);
    next.events = setEvent(next, 'DEAT', f.ddate, f.dplace);
    const occ = eventOf(person, 'OCCU');
    if (f.occ.trim()) next.events = [...next.events.filter((e) => e !== occ), { id: occ?.id ?? newId('ev'), type: 'OCCU', value: f.occ.trim(), citations: occ?.citations ?? [] }];
    else next.events = next.events.filter((e) => e !== occ);
    await store.editPerson(next, person);
    setEditing(false);
    store.toast('Profile saved');
  };

  const parents = graph.parents(person.id);
  const partners = graph.partners(person.id);
  const kids = graph.children(person.id);
  const sibs = graph.siblings(person.id);
  const citations = person.events.flatMap((e) => e.citations.map((c) => ({ e, c })));

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-2xl font-semibold">{displayName(person)}</h2>
        <div className="muted text-sm">{person.gedcomId ?? person.id} · {person.sex ?? 'sex not recorded'} · {person.privacy}{person.traditional ? ' · traditional narrative' : person.historical ? ' · historical' : ''}</div>
        {person.names.length > 1 && <div className="text-sm muted">Also known as: {person.names.slice(1).map((n) => n.full).join(', ')}</div>}
        <div className="mt-3 flex flex-wrap gap-2">
          <button className="btn btn-primary" onClick={() => setEditing(!editing)} data-testid="edit-person">{editing ? 'Cancel' : 'Edit'}</button>
          <button className="btn" onClick={() => store.setRoot(person.id)} disabled={workspace?.rootPersonId === person.id}>Set as home person</button>
          <button className="btn" onClick={() => setRelMode('parent')}>+ Parent</button>
          <button className="btn" onClick={() => setRelMode('partner')}>+ Partner</button>
          <button className="btn" onClick={() => setRelMode('child')}>+ Child</button>
          <button className="btn btn-danger" onClick={async () => { if (confirm(`Delete ${displayName(person)}? Family links are removed. This is recorded in the audit log.`)) { try { await deletePerson(person); store.select(undefined); await store.reload(); } catch (e) { alert((e as Error).message); } } }}>Delete</button>
        </div>
      </div>
      {relMode && <AddRelative person={person} mode={relMode} onDone={() => setRelMode('')} />}
      {editing ? (
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="Given names" v={f.given} on={(given) => setF({ ...f, given })} testId="given" />
          <Field label="Surname" v={f.surname} on={(surname) => setF({ ...f, surname })} />
          <label className="text-sm">Sex (as documented)<select className="input mt-1" value={f.sex} onChange={(e) => setF({ ...f, sex: e.target.value })}><option value="">Not recorded</option><option value="M">Male</option><option value="F">Female</option><option value="X">Other / intersex</option><option value="U">Unknown</option></select></label>
          <label className="text-sm">Privacy<select className="input mt-1" value={f.privacy} onChange={(e) => setF({ ...f, privacy: e.target.value })}><option value="private">Private</option><option value="living-private">Living — private (redacted on export)</option><option value="public">Public</option></select></label>
          <Field label="Birth date (e.g. ABT 1850, 4 JUN 1875)" v={f.bdate} on={(bdate) => setF({ ...f, bdate })} />
          <Field label="Birth place" v={f.bplace} on={(bplace) => setF({ ...f, bplace })} />
          <Field label="Death date" v={f.ddate} on={(ddate) => setF({ ...f, ddate })} />
          <Field label="Death place" v={f.dplace} on={(dplace) => setF({ ...f, dplace })} />
          <Field label="Occupation" v={f.occ} on={(occ) => setF({ ...f, occ })} />
          <div className="flex flex-col gap-2 text-sm">
            <label><input type="checkbox" checked={f.historical} onChange={(e) => setF({ ...f, historical: e.target.checked })} /> Public historical profile</label>
            <label><input type="checkbox" checked={f.traditional} onChange={(e) => setF({ ...f, traditional: e.target.checked })} /> Traditional / legendary narrative (not verified history)</label>
          </div>
          <label className="text-sm sm:col-span-2">Biography<textarea className="input mt-1" rows={3} value={f.bio} onChange={(e) => setF({ ...f, bio: e.target.value })} /></label>
          <label className="text-sm sm:col-span-2">Research notes<textarea className="input mt-1" rows={3} value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} /></label>
          <div className="sm:col-span-2"><button className="btn btn-primary" onClick={save} data-testid="save-person">Save changes</button></div>
        </div>
      ) : (
        <>
          <section>
            <div className="label mb-1">Life events</div>
            <table className="data"><tbody>
              {person.events.filter((e) => e.type !== '_CITE').map((e) => (
                <tr key={e.id}><td className="font-medium">{EVENT_NAMES[e.type] ?? e.type}{e.description ? ` (${e.description})` : ''}</td><td>{dateLabel(e.date)}{e.value ? ` ${e.value}` : ''}</td><td className="muted">{e.place}</td><td><BasisChip basis={e.citations.length ? 'documented' : 'missing'} /></td></tr>
              ))}
            </tbody></table>
            {!person.events.length && <div className="muted text-sm">No events recorded.</div>}
          </section>
          {person.biography && <section><div className="label">Biography</div><p className="text-sm whitespace-pre-wrap">{person.biography}</p></section>}
          {person.researchNotes && <section><div className="label">Research notes</div><p className="text-sm whitespace-pre-wrap">{person.researchNotes}</p></section>}
          {person.notes.length > 0 && <section><div className="label">Notes (imported)</div>{person.notes.map((n, i) => <p key={i} className="text-sm whitespace-pre-wrap">{n}</p>)}</section>}
        </>
      )}
      <section className="grid gap-3 sm:grid-cols-2">
        <Rel title="Parents">{parents.map((p) => <li key={p.personId + p.familyId}><PersonLink id={p.personId} /> {p.relation !== 'birth' && <span className="chip chip-inf">{p.relation}</span>} <BasisChip basis={linkEvidence(graph, person.id, p.familyId).length ? 'documented' : 'missing'} /></li>)}</Rel>
        <Rel title="Partners">{partners.map((p) => <li key={p.personId + p.familyId}><PersonLink id={p.personId} /></li>)}</Rel>
        <Rel title="Siblings">{sibs.map((s) => <li key={s.personId}><PersonLink id={s.personId} /> {s.kind !== 'full' && <span className="chip">{s.kind}</span>}</li>)}</Rel>
        <Rel title="Children">{kids.map((c) => <li key={c.personId + c.familyId}><PersonLink id={c.personId} /> {c.relation !== 'birth' && <span className="chip chip-inf">{c.relation}</span>}</li>)}</Rel>
      </section>
      <section>
        <div className="label mb-1">Sources & citations</div>
        {citations.length ? <ul className="text-sm space-y-1">{citations.map(({ e, c }, i) => <li key={i}>{EVENT_NAMES[e.type] ?? e.type}: <b>{sources.find((s) => s.id === c.sourceId)?.title ?? c.sourceId.replace(/^inline:/, '')}</b>{c.page ? `, ${c.page}` : ''}{c.quality !== undefined ? ` (quality ${c.quality}/3)` : ''}</li>)}</ul> : <p className="text-sm muted">No citations. Facts on this profile are unsourced.</p>}
        <AddCitation person={person} />
      </section>
      {person.extensions.length > 0 && <section><div className="label mb-1">Preserved GEDCOM extensions</div><pre className="panel-2 overflow-auto p-2 text-xs">{person.extensions.map((x) => x.lines.join('\n')).join('\n')}</pre></section>}
    </div>
  );
}

const EVENT_NAMES: Record<string, string> = { BIRT: 'Birth', DEAT: 'Death', CHR: 'Christening', BAPM: 'Baptism', BURI: 'Burial', RESI: 'Residence', OCCU: 'Occupation', MARR: 'Marriage', DIV: 'Divorce', ADOP: 'Adoption', EVEN: 'Event', EMIG: 'Emigration', IMMI: 'Immigration', CENS: 'Census', EDUC: 'Education', NATU: 'Naturalization' };

function formOf(p: Person) {
  const b = eventOf(p, 'BIRT'), d = eventOf(p, 'DEAT');
  return { given: p.names[0]?.given ?? '', surname: p.names[0]?.surname ?? '', sex: p.sex ?? '', privacy: p.privacy as string, bdate: b?.date?.raw ?? '', bplace: b?.place ?? '', ddate: d?.date?.raw ?? '', dplace: d?.place ?? '', occ: eventOf(p, 'OCCU')?.value ?? '', bio: p.biography ?? '', notes: p.researchNotes ?? '', historical: !!p.historical, traditional: !!p.traditional };
}
const Field = ({ label, v, on, testId }: { label: string; v: string; on: (s: string) => void; testId?: string }) => <label className="text-sm">{label}<input className="input mt-1" value={v} onChange={(e) => on(e.target.value)} data-testid={testId} /></label>;
const Rel = ({ title, children }: { title: string; children: React.ReactNode[] }) => <div className="panel-2 p-3"><div className="label mb-1">{title}</div>{children.length ? <ul className="space-y-1 text-sm">{children}</ul> : <div className="text-sm muted">None recorded</div>}</div>;

function AddRelative({ person, mode, onDone }: { person: Person; mode: 'parent' | 'child' | 'partner'; onDone: () => void }) {
  const store = useStore();
  const [existing, setExisting] = useState<string>();
  const [given, setGiven] = useState('');
  const [surname, setSurname] = useState(mode === 'partner' ? '' : person.names[0]?.surname ?? '');
  const [sex, setSex] = useState<Person['sex'] | ''>('');
  const [rel, setRel] = useState<ChildRelation>('birth');
  const go = async () => {
    const ws = person.workspaceId;
    let otherId = existing;
    if (!otherId) {
      if (!given.trim() && !surname.trim()) return;
      const np = blankPerson(ws, given.trim(), surname.trim(), sex || undefined);
      await store.editPerson(np);
      otherId = np.id;
    }
    const g = store.graph;
    const now = Date.now();
    const blankFam = (partnerIds: string[], children: Family['children']): Family => ({ id: newId('fam'), workspaceId: ws, partnerIds, children, events: [], notes: [], extensions: [], updatedAt: now });
    if (mode === 'partner') await store.editFamily(blankFam([person.id, otherId], []));
    else if (mode === 'child') {
      const fam = g.spouseFamilies(person.id)[0];
      if (fam) await store.editFamily({ ...fam, children: [...fam.children, { personId: otherId, relation: rel }] }, fam);
      else await store.editFamily(blankFam([person.id], [{ personId: otherId, relation: rel }]));
    } else {
      const fam = g.childFamilies(person.id).find((f) => f.partnerIds.length < 2);
      if (fam) await store.editFamily({ ...fam, partnerIds: [...fam.partnerIds, otherId] }, fam);
      else await store.editFamily(blankFam([otherId], [{ personId: person.id, relation: rel }]));
    }
    store.toast(`${mode} linked`);
    onDone();
  };
  return (
    <div className="panel-2 space-y-2 p-3">
      <div className="font-semibold">Add {mode}</div>
      <PersonPicker label="Link an existing person" value={existing} onChange={setExisting} />
      {!existing && <div className="grid gap-2 sm:grid-cols-3">
        <input className="input" placeholder="Given names" value={given} onChange={(e) => setGiven(e.target.value)} aria-label="Given names" />
        <input className="input" placeholder="Surname" value={surname} onChange={(e) => setSurname(e.target.value)} aria-label="Surname" />
        <select className="input" value={sex} onChange={(e) => setSex(e.target.value as Person['sex'])} aria-label="Sex"><option value="">Sex not recorded</option><option value="M">Male</option><option value="F">Female</option></select>
      </div>}
      {mode !== 'partner' && <label className="text-sm block">Relationship type<select className="input mt-1" value={rel} onChange={(e) => setRel(e.target.value as ChildRelation)}><option value="birth">Biological (birth)</option><option value="adopted">Adoptive</option><option value="step">Step</option><option value="foster">Foster</option><option value="unknown">Unknown</option></select></label>}
      <div className="flex gap-2"><button className="btn btn-primary" onClick={go}>Save link</button><button className="btn" onClick={onDone}>Cancel</button></div>
    </div>
  );
}

function AddCitation({ person }: { person: Person }) {
  const store = useStore();
  const [open, setOpen] = useState(false);
  const [sourceId, setSourceId] = useState('');
  const [newTitle, setNewTitle] = useState('');
  const [eventId, setEventId] = useState('');
  const [page, setPage] = useState('');
  if (!open) return <button className="btn mt-2" onClick={() => setOpen(true)}>+ Add citation</button>;
  const save = async () => {
    const { getDb } = await import('../database/db');
    let sid = sourceId;
    if (!sid && newTitle.trim()) { sid = newId('sour'); await getDb().sources.add({ id: sid, workspaceId: person.workspaceId, title: newTitle.trim() }); }
    if (!sid) return;
    const target = person.events.find((e) => e.id === eventId);
    const events = target
      ? person.events.map((e) => (e === target ? { ...e, citations: [...e.citations, { sourceId: sid, page: page || undefined }] } : e))
      : [...person.events, { id: newId('ev'), type: '_CITE', citations: [{ sourceId: sid, page: page || undefined }] }];
    await store.editPerson({ ...person, events }, person);
    setOpen(false);
  };
  return (
    <div className="panel-2 mt-2 grid gap-2 p-3 sm:grid-cols-2">
      <select className="input" value={sourceId} onChange={(e) => setSourceId(e.target.value)} aria-label="Source"><option value="">— new source —</option>{store.sources.map((s) => <option key={s.id} value={s.id}>{s.title}</option>)}</select>
      {!sourceId && <input className="input" placeholder="New source title" value={newTitle} onChange={(e) => setNewTitle(e.target.value)} aria-label="New source title" />}
      <select className="input" value={eventId} onChange={(e) => setEventId(e.target.value)} aria-label="Fact"><option value="">Whole profile</option>{person.events.filter((e) => e.type !== '_CITE').map((e) => <option key={e.id} value={e.id}>{EVENT_NAMES[e.type] ?? e.type} {dateLabel(e.date)}</option>)}</select>
      <input className="input" placeholder="Page / detail" value={page} onChange={(e) => setPage(e.target.value)} aria-label="Page" />
      <div className="flex gap-2"><button className="btn btn-primary" onClick={save}>Save citation</button><button className="btn" onClick={() => setOpen(false)}>Cancel</button></div>
    </div>
  );
}
