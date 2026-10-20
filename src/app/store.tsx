import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { getDb } from '../database/db';
import { loadWorkspaceData, savePerson, saveFamily, updateWorkspace } from '../database/repo';
import type { DnaKit, Family, GedcomImport, ID, Person, Source, TreeWorkspace } from '../database/types';
import { FamilyGraph } from '../genealogy/graph/familyGraph';

type Snapshot = { kind: 'person'; before?: Person; after: Person } | { kind: 'family'; before?: Family; after: Family };

interface Store {
  workspaces: TreeWorkspace[];
  workspace?: TreeWorkspace;
  persons: Person[];
  families: Family[];
  sources: Source[];
  imports: GedcomImport[];
  kits: DnaKit[];
  graph: FamilyGraph;
  loading: boolean;
  selectedId?: ID;
  vaultKey?: CryptoKey;
  theme: 'dark' | 'light';
  version: number;
  select(id?: ID): void;
  openWorkspace(id: ID | undefined): Promise<void>;
  reload(): Promise<void>;
  setVaultKey(k?: CryptoKey): void;
  setTheme(t: 'dark' | 'light'): void;
  setRoot(id: ID): Promise<void>;
  editPerson(next: Person, before?: Person): Promise<void>;
  editFamily(next: Family, before?: Family): Promise<void>;
  undo(): Promise<void>;
  redo(): Promise<void>;
  canUndo: boolean;
  canRedo: boolean;
  toast(msg: string): void;
  toasts: string[];
}

const Ctx = createContext<Store | null>(null);
export const useStore = () => { const s = useContext(Ctx); if (!s) throw new Error('StoreProvider missing'); return s; };

const LAST_WS = 'omnitree.lastWorkspace';
const safeGet = (k: string) => { try { return localStorage.getItem(k) ?? undefined; } catch { return undefined; } };
const safeSet = (k: string, v?: string) => { try { if (v) localStorage.setItem(k, v); else localStorage.removeItem(k); } catch { /* storage unavailable */ } };

export function StoreProvider({ children }: { children: ReactNode }) {
  const [workspaces, setWorkspaces] = useState<TreeWorkspace[]>([]);
  const [workspace, setWorkspace] = useState<TreeWorkspace>();
  const [data, setData] = useState({ persons: [] as Person[], families: [] as Family[], sources: [] as Source[], imports: [] as GedcomImport[], kits: [] as DnaKit[], graph: new FamilyGraph([], []) });
  const [loading, setLoading] = useState(true);
  const [selectedId, select] = useState<ID>();
  const [vaultKey, setVaultKey] = useState<CryptoKey>();
  const [theme, setThemeState] = useState<'dark' | 'light'>((safeGet('omnitree.theme') as 'dark' | 'light') ?? 'dark');
  const [undoStack, setUndo] = useState<Snapshot[]>([]);
  const [redoStack, setRedo] = useState<Snapshot[]>([]);
  const [version, setVersion] = useState(0);
  const [toasts, setToasts] = useState<string[]>([]);

  const toast = useCallback((m: string) => { setToasts((t) => [...t, m]); setTimeout(() => setToasts((t) => t.slice(1)), 4000); }, []);

  const loadData = useCallback(async (ws?: TreeWorkspace) => {
    if (!ws) { setData({ persons: [], families: [], sources: [], imports: [], kits: [], graph: new FamilyGraph([], []) }); return; }
    const d = await loadWorkspaceData(ws.id);
    setData(d);
    setVersion((v) => v + 1);
  }, []);

  const openWorkspace = useCallback(async (id: ID | undefined) => {
    setLoading(true);
    const all = await getDb().workspaces.toArray();
    setWorkspaces(all);
    const ws = id ? all.find((w) => w.id === id) : undefined;
    setWorkspace(ws);
    safeSet(LAST_WS, ws?.id);
    setVaultKey(undefined);
    setUndo([]); setRedo([]);
    select(ws?.rootPersonId);
    await loadData(ws);
    setLoading(false);
  }, [loadData]);

  useEffect(() => { openWorkspace(safeGet(LAST_WS)).catch(() => setLoading(false)); }, [openWorkspace]);
  useEffect(() => {
    document.documentElement.classList.toggle('dark', theme === 'dark');
    document.documentElement.dataset.theme = theme;
    safeSet('omnitree.theme', theme);
  }, [theme]);

  const reload = useCallback(async () => {
    const all = await getDb().workspaces.toArray();
    setWorkspaces(all);
    const ws = workspace && all.find((w) => w.id === workspace.id);
    setWorkspace(ws);
    await loadData(ws);
  }, [workspace, loadData]);

  const apply = useCallback(async (s: Snapshot, dir: 'do' | 'undo') => {
    const target = dir === 'do' ? s.after : s.before;
    if (s.kind === 'person') {
      if (target) await savePerson(target as Person, dir === 'undo' ? 'undo' : 'edit');
      else await getDb().persons.delete(s.after.id);
    } else {
      if (target) await saveFamily(target as Family, dir === 'undo' ? 'undo' : 'edit');
      else await getDb().families.delete(s.after.id);
    }
  }, []);

  const editPerson = useCallback(async (after: Person, before?: Person) => {
    const s: Snapshot = { kind: 'person', before, after };
    await apply(s, 'do');
    setUndo((u) => [...u.slice(-99), s]); setRedo([]);
    await reload();
  }, [apply, reload]);
  const editFamily = useCallback(async (after: Family, before?: Family) => {
    const s: Snapshot = { kind: 'family', before, after };
    await apply(s, 'do');
    setUndo((u) => [...u.slice(-99), s]); setRedo([]);
    await reload();
  }, [apply, reload]);
  const undo = useCallback(async () => {
    const s = undoStack[undoStack.length - 1];
    if (!s) return;
    await apply(s, 'undo');
    setUndo((u) => u.slice(0, -1)); setRedo((r) => [...r, s]);
    await reload();
  }, [undoStack, apply, reload]);
  const redo = useCallback(async () => {
    const s = redoStack[redoStack.length - 1];
    if (!s) return;
    await apply(s, 'do');
    setRedo((r) => r.slice(0, -1)); setUndo((u) => [...u, s]);
    await reload();
  }, [redoStack, apply, reload]);

  const setRoot = useCallback(async (id: ID) => {
    if (!workspace) return;
    const ws = { ...workspace, rootPersonId: id };
    await updateWorkspace(ws);
    setWorkspace(ws);
    toast('Home person updated');
  }, [workspace, toast]);

  const value = useMemo<Store>(() => ({
    workspaces, workspace, ...data, loading, selectedId, vaultKey, theme, version,
    select, openWorkspace, reload, setVaultKey, setTheme: setThemeState, setRoot, editPerson, editFamily, undo, redo,
    canUndo: undoStack.length > 0, canRedo: redoStack.length > 0, toast, toasts,
  }), [workspaces, workspace, data, loading, selectedId, vaultKey, theme, version, openWorkspace, reload, setRoot, editPerson, editFamily, undo, redo, undoStack.length, redoStack.length, toast, toasts]);

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}
