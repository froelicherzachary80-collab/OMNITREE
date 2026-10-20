import { OmniAgent, type AgentAnswer } from '../agent/omniAgent';
import type { FamilyGraph } from '../../genealogy/graph/familyGraph';

/** Minimal chat-completion interface so the model runtime is swappable (and mockable in tests). */
export interface ChatEngine {
  complete(messages: { role: 'system' | 'user'; content: string }[]): Promise<string>;
}

const INTENT_HELP: Record<string, string> = {
  parents: 'parents and grandparents of a person', ancestors: 'all known ancestors', maternal: 'maternal line', paternal: 'paternal line',
  descendants: 'descendants of a person', place: 'people with events in a named place', duplicates: 'possible duplicate profiles',
  missing_birth: 'people without birth dates', relationship: 'how two people are related', earliest: 'earliest dated person',
  weak_evidence: 'parent-child links without sources', research_plan: 'research plan for a person', relationship_sources: 'sources for a relationship',
  compare_dna: 'compare two DNA kits', dna_summary: 'what uploaded DNA can establish',
};

/**
 * Ask the model to choose ONE supported tool for a question. The reply is validated against the
 * tool list; anything else returns undefined and the deterministic router stays in charge.
 */
export async function planIntent(engine: ChatEngine, question: string): Promise<string | undefined> {
  const names = OmniAgent.intentNames();
  const reply = await engine.complete([
    { role: 'system', content: `You route genealogy questions to tools. Reply with JSON only: {"tool":"<name>"} or {"tool":"none"}.\nTools:\n${names.map((n) => `- ${n}: ${INTENT_HELP[n] ?? n}`).join('\n')}` },
    { role: 'user', content: question },
  ]);
  const m = reply.match(/"tool"\s*:\s*"([a-z_]+)"/);
  return m && names.includes(m[1]) ? m[1] : undefined;
}

export interface Phrasing { text: string; accepted: boolean; reason?: string }

/**
 * Grounding guard: a model rephrase is accepted only if every person name it mentions belongs to
 * the tool result, and every year it mentions appears in the tool facts. Otherwise it is discarded.
 */
export function checkGrounding(text: string, answer: AgentAnswer, graph: FamilyGraph): { ok: boolean; reason?: string } {
  const allowed = new Set(answer.personIds);
  const lower = text.toLowerCase();
  for (const p of graph.persons.values()) {
    if (allowed.has(p.id)) continue;
    const full = p.names[0]?.full;
    if (full && full.includes(' ') && lower.includes(full.toLowerCase())) {
      // Same-name people in the result are fine (e.g. two Henry Thornwoods).
      if ([...allowed].some((id) => graph.persons.get(id)?.names[0]?.full === full)) continue;
      return { ok: false, reason: `mentions ${full}, who is not in the tool result` };
    }
  }
  const factText = [answer.text, ...answer.results.flatMap((r) => r.facts.map((f) => f.statement))].join(' ');
  for (const y of text.match(/\b(1[0-9]{3}|20[0-9]{2})\b/g) ?? []) if (!factText.includes(y)) return { ok: false, reason: `mentions year ${y}, which is not in the tool facts` };
  for (const n of text.match(/\b\d+(\.\d+)?\s*(cM|centimorgans?|%)/gi) ?? []) if (!factText.includes(n.replace(/\s+/g, ' ').split(' ')[0])) return { ok: false, reason: `introduces the figure "${n}"` };
  return { ok: true };
}

export async function phraseAnswer(engine: ChatEngine, question: string, answer: AgentAnswer, graph: FamilyGraph): Promise<Phrasing> {
  const facts = answer.results.flatMap((r) => [r.summary, ...r.facts.slice(0, 25).map((f) => `- ${f.statement} [${f.basis}]`), ...r.caveats.map((c) => `Note: ${c}`)]).join('\n');
  const text = (await engine.complete([
    { role: 'system', content: 'You summarise genealogy tool results. Use ONLY the facts given. Do not add names, dates, places, relationships or numbers. Keep "inferred" and "missing evidence" qualifiers. 2-4 sentences.' },
    { role: 'user', content: `Question: ${question}\nTool results:\n${facts}` },
  ])).trim();
  const g = checkGrounding(text, answer, graph);
  return { text, accepted: g.ok, reason: g.reason };
}

/** Load a WebLLM model in the browser (WebGPU required). Download size is shown to the user before calling. */
export async function loadWebLLM(modelId: string, onProgress: (p: { progress: number; text: string }) => void): Promise<ChatEngine> {
  const webllm = await import('@mlc-ai/web-llm');
  const engine = await webllm.CreateMLCEngine(modelId, { initProgressCallback: (r) => onProgress({ progress: r.progress, text: r.text }) });
  return {
    async complete(messages) {
      const r = await engine.chat.completions.create({ messages, temperature: 0, max_tokens: 300 });
      return r.choices[0]?.message?.content ?? '';
    },
  };
}
