import { useEffect, useMemo, useRef, useState } from 'react';
import { useStore } from '../app/store';
import { OmniAgent, SUGGESTED_QUESTIONS, type AgentAnswer } from '../ai/agent/omniAgent';
import { BasisChip, Card, PersonLink, PersonPicker } from '../components/common';
import { readKitVariants } from '../database/repo';
import { OmniMemory } from '../ai/memory/omniMemory';
import { getDb } from '../database/db';
import { newId, type AiResearchSession } from '../database/types';
import { detectCapabilities, MODEL_CATALOG, type Capabilities } from '../ai/models/localModel';

interface Msg { role: 'user' | 'assistant'; text: string; answer?: AgentAnswer }

export default function OmniAIPage() {
  const store = useStore();
  const { graph, sources, workspace, selectedId, kits, vaultKey } = store;
  const [q, setQ] = useState('');
  const [msgs, setMsgs] = useState<Msg[]>([]);
  const [busy, setBusy] = useState(false);
  const [review, setReview] = useState<AgentAnswer>();
  const [caps, setCaps] = useState<Capabilities>();
  const session = useRef<AiResearchSession>();
  const endRef = useRef<HTMLDivElement>(null);
  const agent = useMemo(() => new OmniAgent({ graph, sources, rootId: workspace?.rootPersonId, selectedId, kits, loadVariants: (k) => readKitVariants(k, vaultKey) }), [graph, sources, workspace?.rootPersonId, selectedId, kits, vaultKey]);
  useEffect(() => { detectCapabilities().then(setCaps); }, []);
  useEffect(() => endRef.current?.scrollIntoView({ behavior: 'smooth' }), [msgs]);

  const ask = async (text: string) => {
    if (!text.trim() || !workspace) return;
    setBusy(true); setQ('');
    setMsgs((m) => [...m, { role: 'user', text }]);
    try {
      const answer = await agent.ask(text);
      setMsgs((m) => [...m, { role: 'assistant', text: answer.text, answer }]);
      session.current ??= { id: newId('ai'), workspaceId: workspace.id, createdAt: Date.now(), messages: [] };
      session.current.messages.push({ role: 'user', text, at: Date.now() }, { role: 'assistant', text: answer.text, at: Date.now(), personIds: answer.personIds.slice(0, 50) });
      await getDb().aiSessions.put(session.current);
    } catch (e) {
      setMsgs((m) => [...m, { role: 'assistant', text: `Error: ${(e as Error).message}` }]);
    } finally { setBusy(false); }
  };

  return (
    <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_320px]">
      <Card title={<span>Omni<span className="gold">AI</span> research assistant</span>}>
        <p className="text-sm muted mb-3">Every answer is computed by OmniTree’s genealogy tools over your local database, with profile IDs, citations and an explicit evidence basis. Nothing is invented.</p>
        <div className="space-y-3 max-h-[60vh] overflow-auto pr-1" aria-live="polite">
          {msgs.length === 0 && <div className="flex flex-wrap gap-2">{SUGGESTED_QUESTIONS.map((s) => <button key={s} className="chip hover:border-emerald-500 py-1" onClick={() => ask(s)}>{s}</button>)}</div>}
          {msgs.map((m, i) => m.role === 'user'
            ? <div key={i} className="ml-auto max-w-[85%] rounded-2xl bg-emerald-600 px-4 py-2 text-white">{m.text}</div>
            : <Answer key={i} m={m} onPropose={() => setReview(m.answer)} />)}
          {busy && <div className="muted text-sm">OmniAI is querying your tree…</div>}
          <div ref={endRef} />
        </div>
        <form className="mt-3 flex gap-2" onSubmit={(e) => { e.preventDefault(); ask(q); }}>
          <input className="input" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Ask about your family…" aria-label="Ask OmniAI" data-testid="ai-input" />
          <button className="btn btn-primary" disabled={busy}>Ask</button>
        </form>
      </Card>
      <div className="space-y-4">
        <Card title="Context">
          <PersonPicker label="“This person”" value={selectedId} onChange={(id) => store.select(id)} />
          <p className="mt-2 text-xs muted">“My/me” refers to the home person{workspace?.rootPersonId ? '' : ' (not set — choose one in a profile)'}. For two-person questions, name both people or use the home + selected person.</p>
        </Card>
        <Card title="Local language model">
          <p className="text-sm">WebGPU: <b>{caps ? (caps.webgpu ? 'available' : 'not available') : '…'}</b> · WASM: <b>{caps?.wasm ? 'yes' : '…'}</b>{caps?.deviceMemoryGB ? ` · ~${caps.deviceMemoryGB} GB RAM` : ''}</p>
          <ul className="mt-2 text-xs muted space-y-1">{MODEL_CATALOG.map((m) => <li key={m.id}>{m.label}: {m.downloadMB} MB download, ~{m.memoryGB} GB memory</li>)}</ul>
          <p className="mt-2 text-xs muted">Not enabled in v0.1: the deterministic engine above answers every supported command without a model. Optional model loading is on the roadmap and will only phrase tool results.</p>
        </Card>
        <MemoryPanel />
      </div>
      {review && <ReviewDialog answer={review} onClose={() => setReview(undefined)} />}
    </div>
  );
}

function Answer({ m, onPropose }: { m: Msg; onPropose: () => void }) {
  const a = m.answer;
  if (!a || !a.results.length) return (
    <div className="panel-2 p-3 text-sm whitespace-pre-wrap">{m.text}
      {a?.needsClarification && <ul className="mt-2 space-y-1">{a.needsClarification.candidates.map((id) => <li key={id}><PersonLink id={id} /> <span className="muted text-xs">{id}</span></li>)}</ul>}
    </div>
  );
  return (
    <div className="panel-2 p-3 text-sm space-y-2">
      {a.results.map((r, i) => (
        <div key={i}>
          <div className="font-semibold">{r.summary}</div>
          <ul className="mt-1 space-y-1">{r.facts.slice(0, 60).map((f, j) => <li key={j} className="flex flex-wrap items-start gap-2"><BasisChip basis={f.basis} /><span className="flex-1">{f.statement}</span></li>)}</ul>
          {r.facts.length > 60 && <div className="muted text-xs">…{r.facts.length - 60} more</div>}
          {r.caveats.map((c, j) => <div key={j} className="text-xs muted">Note: {c}</div>)}
        </div>
      ))}
      {a.personIds.length > 0 && <div className="text-xs"><span className="label">Profiles:</span> {a.personIds.slice(0, 12).map((id) => <span key={id} className="mr-2"><PersonLink id={id} showYears={false} /></span>)}{a.personIds.length > 12 && `+${a.personIds.length - 12}`}</div>}
      <button className="btn" onClick={onPropose}>Propose as research hypothesis…</button>
    </div>
  );
}

/** Review screen: nothing is written until the user approves. */
function ReviewDialog({ answer, onClose }: { answer: AgentAnswer; onClose: () => void }) {
  const { workspace, toast, reload } = useStore();
  const [title, setTitle] = useState(answer.results[0]?.summary ?? '');
  const [keep, setKeep] = useState(() => new Set(answer.results.flatMap((r) => r.facts.map((_, i) => i)).slice(0, 10)));
  const facts = answer.results.flatMap((r) => r.facts);
  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/60 p-4" role="dialog" aria-modal>
      <div className="panel max-h-[85vh] w-full max-w-xl overflow-auto p-4 space-y-3">
        <h2 className="text-lg font-semibold">Review proposed hypothesis</h2>
        <p className="text-sm muted">This creates a hypothesis in your Research Library. It does not change any person or relationship.</p>
        <input className="input" value={title} onChange={(e) => setTitle(e.target.value)} aria-label="Hypothesis title" />
        <ul className="space-y-1 text-sm">{facts.slice(0, 40).map((f, i) => <li key={i}><label className="flex gap-2"><input type="checkbox" checked={keep.has(i)} onChange={(e) => { const n = new Set(keep); e.target.checked ? n.add(i) : n.delete(i); setKeep(n); }} /><span>{f.statement} <BasisChip basis={f.basis} /></span></label></li>)}</ul>
        <div className="flex gap-2">
          <button className="btn btn-primary" onClick={async () => { await OmniMemory.addHypothesis(workspace!.id, title, answer.personIds.slice(0, 50), facts.filter((_, i) => keep.has(i)).map((f) => f.statement)); toast('Hypothesis saved for review'); await reload(); onClose(); }}>Approve & save</button>
          <button className="btn" onClick={onClose}>Reject</button>
        </div>
      </div>
    </div>
  );
}

function MemoryPanel() {
  const { workspace, version } = useStore();
  const [facts, setFacts] = useState<Awaited<ReturnType<typeof OmniMemory.list>>>([]);
  useEffect(() => { workspace && OmniMemory.list(workspace.id).then(setFacts); }, [workspace, version]);
  return (
    <Card title="OmniMemory">
      {facts.length ? <ul className="text-xs space-y-1">{facts.slice(0, 12).map((f) => <li key={f.id}><span className="chip mr-1">{f.kind}</span>{f.text}</li>)}</ul> : <p className="text-xs muted">Confirmed/rejected matches and approved facts appear here.</p>}
    </Card>
  );
}
