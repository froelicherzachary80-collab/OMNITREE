import { useEffect, useState } from 'react';

export const ROUTES = [
  { id: 'home', label: 'Home', icon: '⌂' },
  { id: 'tree', label: 'My Family Tree', icon: '🌳' },
  { id: 'world', label: 'World Family Tree', icon: '🌐' },
  { id: 'ai', label: 'OmniAI', icon: '✦' },
  { id: 'dna', label: 'OmniDNA', icon: '🧬' },
  { id: 'discover', label: 'Discover Ancestors', icon: '🔍' },
  { id: 'relationships', label: 'Relationships', icon: '⇄' },
  { id: 'map', label: 'World Map', icon: '🗺' },
  { id: 'timeline', label: 'History Timeline', icon: '⏳' },
  { id: 'library', label: 'Research Library', icon: '📚' },
  { id: 'io', label: 'Import / Export', icon: '⇅' },
  { id: 'settings', label: 'Settings', icon: '⚙' },
] as const;
export type RouteId = (typeof ROUTES)[number]['id'];

const current = (): RouteId => {
  const h = location.hash.replace(/^#\/?/, '') as RouteId;
  return ROUTES.some((r) => r.id === h) ? h : 'home';
};

export function navigate(r: RouteId) { location.hash = `/${r}`; }

export function useRoute(): RouteId {
  const [r, setR] = useState<RouteId>(current());
  useEffect(() => {
    const f = () => { setR(current()); window.scrollTo(0, 0); };
    window.addEventListener('hashchange', f);
    return () => window.removeEventListener('hashchange', f);
  }, []);
  return r;
}
