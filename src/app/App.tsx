import { lazy, Suspense, useState } from 'react';
import { useStore } from './store';
import { navigate, ROUTES, useRoute } from './router';
import { Onboarding } from '../pages/Onboarding';
import { Home } from '../pages/Home';
import { Progress } from '../components/common';

const TreePage = lazy(() => import('../pages/TreePage'));
const WorldTree = lazy(() => import('../pages/WorldTree'));
const OmniAIPage = lazy(() => import('../pages/OmniAIPage'));
const DnaPage = lazy(() => import('../pages/DnaPage'));
const DiscoverPage = lazy(() => import('../pages/DiscoverPage'));
const RelationshipsPage = lazy(() => import('../pages/RelationshipsPage'));
const MapPage = lazy(() => import('../pages/MapPage'));
const TimelinePage = lazy(() => import('../pages/TimelinePage'));
const LibraryPage = lazy(() => import('../pages/LibraryPage'));
const ImportExportPage = lazy(() => import('../pages/ImportExportPage'));
const SettingsPage = lazy(() => import('../pages/SettingsPage'));

const PAGES = { tree: TreePage, world: WorldTree, ai: OmniAIPage, dna: DnaPage, discover: DiscoverPage, relationships: RelationshipsPage, map: MapPage, timeline: TimelinePage, library: LibraryPage, io: ImportExportPage, settings: SettingsPage } as const;
const MOBILE_TABS = ['home', 'tree', 'ai', 'dna'] as const;

export function App() {
  const store = useStore();
  const route = useRoute();
  const [menu, setMenu] = useState(false);
  if (store.loading) return <div className="grid h-full place-items-center"><div className="w-64"><Progress label="Loading OmniTree" /></div></div>;
  if (!store.workspace) return <Onboarding />;
  const Page = route === 'home' ? Home : PAGES[route];
  return (
    <div className="min-h-full md:flex">
      <aside className="hidden md:flex md:w-60 md:flex-col md:border-r md:border-[color:var(--border)] md:p-4 sticky top-0 h-screen overflow-auto">
        <Brand />
        <nav className="mt-6 flex flex-col gap-1" aria-label="Main">
          {ROUTES.map((r) => (
            <a key={r.id} href={`#/${r.id}`} aria-current={route === r.id ? 'page' : undefined}
              className={`rounded-lg px-3 py-2 text-sm font-medium transition ${route === r.id ? 'bg-emerald-500/15 accent' : 'hover:bg-emerald-500/5'}`}>
              <span className="mr-2 inline-block w-5 text-center" aria-hidden>{r.icon}</span>{r.label}
            </a>
          ))}
        </nav>
        <div className="mt-auto pt-4 text-xs muted">Workspace: <b>{store.workspace.name}</b><br />Local-only · {store.vaultKey ? '🔓 vault unlocked' : store.workspace.vaultEnabled ? '🔒 vault locked' : 'no vault'}</div>
      </aside>
      <div className="flex-1 min-w-0 pb-24 md:pb-6">
        <header className="sticky top-0 z-20 flex items-center gap-2 border-b border-[color:var(--border)] bg-[color:var(--bg)]/90 px-4 py-3 backdrop-blur" style={{ paddingTop: 'max(0.75rem, env(safe-area-inset-top))' }}>
          <div className="md:hidden"><Brand small /></div>
          <h1 className="hidden md:block text-xl font-semibold">{ROUTES.find((r) => r.id === route)?.label}</h1>
          <div className="ml-auto flex gap-2">
            <button className="btn" onClick={store.undo} disabled={!store.canUndo} aria-label="Undo">↶<span className="hidden sm:inline">Undo</span></button>
            <button className="btn" onClick={store.redo} disabled={!store.canRedo} aria-label="Redo">↷<span className="hidden sm:inline">Redo</span></button>
            <button className="btn" onClick={() => store.setTheme(store.theme === 'dark' ? 'light' : 'dark')} aria-label="Toggle theme">{store.theme === 'dark' ? '☀' : '☾'}</button>
          </div>
        </header>
        <main className="mx-auto max-w-7xl p-4">
          <h1 className="md:hidden mb-3 text-xl font-semibold">{ROUTES.find((r) => r.id === route)?.label}</h1>
          <Suspense fallback={<Progress label="Loading page" />}><Page /></Suspense>
        </main>
      </div>
      <nav className="fixed bottom-0 left-0 right-0 z-30 grid grid-cols-5 border-t border-[color:var(--border)] bg-[color:var(--panel)] md:hidden" style={{ paddingBottom: 'env(safe-area-inset-bottom)' }} aria-label="Mobile">
        {MOBILE_TABS.map((id) => { const r = ROUTES.find((x) => x.id === id)!; return (
          <a key={id} href={`#/${id}`} className={`flex flex-col items-center py-2 text-[11px] ${route === id ? 'accent' : 'muted'}`}><span className="text-lg" aria-hidden>{r.icon}</span>{r.label.replace('My Family ', '')}</a>
        ); })}
        <button className={`flex flex-col items-center py-2 text-[11px] ${menu ? 'accent' : 'muted'}`} onClick={() => setMenu(!menu)} aria-expanded={menu}><span className="text-lg" aria-hidden>☰</span>More</button>
      </nav>
      {menu && (
        <div className="fixed inset-0 z-40 bg-black/50 md:hidden" onClick={() => setMenu(false)}>
          <div className="panel absolute bottom-16 left-3 right-3 grid grid-cols-3 gap-2 p-3" onClick={(e) => e.stopPropagation()}>
            {ROUTES.filter((r) => !(MOBILE_TABS as readonly string[]).includes(r.id)).map((r) => (
              <button key={r.id} className="panel-2 flex flex-col items-center gap-1 p-3 text-xs" onClick={() => { navigate(r.id); setMenu(false); }}><span className="text-xl" aria-hidden>{r.icon}</span>{r.label}</button>
            ))}
          </div>
        </div>
      )}
      <div className="fixed right-4 top-16 z-50 flex flex-col gap-2" aria-live="polite">
        {store.toasts.map((t, i) => <div key={i} className="panel px-4 py-2 text-sm">{t}</div>)}
      </div>
    </div>
  );
}

function Brand({ small }: { small?: boolean }) {
  return (
    <a href="#/home" className="flex items-center gap-2">
      <img src="/icon.svg" alt="" className={small ? 'h-7 w-7' : 'h-9 w-9'} />
      <div><div className="font-serif text-lg font-semibold leading-none">Omni<span className="gold">Tree</span></div>{!small && <div className="text-[11px] muted">World Family Tree</div>}</div>
    </a>
  );
}
