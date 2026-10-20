/**
 * Optional local language-model layer.
 *
 * V0.1 status: capability detection and the model catalog are implemented; no model
 * is bundled or downloaded. OmniAI answers come entirely from deterministic tools.
 * A future adapter (WebLLM / Transformers.js) will only rephrase tool results and
 * choose tools — it will never be allowed to assert family connections itself.
 */
export interface ModelOption { id: string; label: string; downloadMB: number; memoryGB: number; runtime: 'webllm' | 'transformers.js' }

export const MODEL_CATALOG: ModelOption[] = [
  { id: 'Qwen2.5-0.5B-Instruct-q4f16_1-MLC', label: 'Qwen2.5 0.5B (fastest)', downloadMB: 945, memoryGB: 1, runtime: 'webllm' },
  { id: 'Llama-3.2-1B-Instruct-q4f16_1-MLC', label: 'Llama 3.2 1B', downloadMB: 879, memoryGB: 1.2, runtime: 'webllm' },
  { id: 'Phi-3.5-mini-instruct-q4f16_1-MLC', label: 'Phi-3.5 mini 3.8B (best quality)', downloadMB: 2200, memoryGB: 3.7, runtime: 'webllm' },
];

export interface Capabilities { webgpu: boolean; wasm: boolean; deviceMemoryGB?: number }

export async function detectCapabilities(): Promise<Capabilities> {
  const nav = typeof navigator !== 'undefined' ? (navigator as Navigator & { gpu?: { requestAdapter(): Promise<unknown> }; deviceMemory?: number }) : undefined;
  let webgpu = false;
  try { webgpu = !!(nav?.gpu && (await nav.gpu.requestAdapter())); } catch { webgpu = false; }
  return { webgpu, wasm: typeof WebAssembly !== 'undefined', deviceMemoryGB: nav?.deviceMemory };
}
