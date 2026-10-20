import { useEffect, useRef, useState } from 'react';
import 'maplibre-gl/dist/maplibre-gl.css';

export interface MapPoint { id: string; lat: number; lon: number; label: string; approximate: boolean; personId: string; color: string }
export interface MapLine { coords: [number, number][]; color: string }

/** Free MapLibre demo basemap (no key). Falls back to the caller's offline view if it fails to load. */
const STYLE_URL = 'https://demotiles.maplibre.org/style.json';

export function MapLibreView({ points, lines, onSelect, onFail }: { points: MapPoint[]; lines: MapLine[]; onSelect: (personId: string) => void; onFail: (reason: string) => void }) {
  const ref = useRef<HTMLDivElement>(null);
  const mapRef = useRef<import('maplibre-gl').Map>();
  const [ready, setReady] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const maplibregl = (await import('maplibre-gl')).default;
        if (cancelled || !ref.current) return;
        const map = new maplibregl.Map({ container: ref.current, style: STYLE_URL, center: [0, 30], zoom: 1.2, attributionControl: { compact: true } });
        mapRef.current = map;
        map.addControl(new maplibregl.NavigationControl(), 'top-right');
        map.on('error', (e) => { if (!map.isStyleLoaded()) onFail(e.error?.message ?? 'Map failed to load'); });
        map.on('load', () => {
          map.addSource('pts', { type: 'geojson', data: { type: 'FeatureCollection', features: [] }, cluster: true, clusterRadius: 40 });
          map.addSource('lines', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
          map.addLayer({ id: 'lines', type: 'line', source: 'lines', paint: { 'line-color': ['get', 'color'], 'line-width': 1.5, 'line-opacity': 0.7 } });
          map.addLayer({ id: 'clusters', type: 'circle', source: 'pts', filter: ['has', 'point_count'], paint: { 'circle-color': '#c9a227', 'circle-radius': ['step', ['get', 'point_count'], 12, 10, 18, 50, 24], 'circle-opacity': 0.85 } });
          map.addLayer({ id: 'cluster-count', type: 'symbol', source: 'pts', filter: ['has', 'point_count'], layout: { 'text-field': ['get', 'point_count_abbreviated'], 'text-size': 11, 'text-font': ['Open Sans Semibold'] } });
          map.addLayer({ id: 'pt', type: 'circle', source: 'pts', filter: ['!', ['has', 'point_count']], paint: { 'circle-color': ['get', 'color'], 'circle-radius': 6, 'circle-stroke-width': ['case', ['get', 'approximate'], 2, 1], 'circle-stroke-color': ['case', ['get', 'approximate'], '#ffffff', '#0b1428'], 'circle-opacity': ['case', ['get', 'approximate'], 0.55, 0.95] } });
          map.on('click', 'pt', (e) => {
            const f = e.features?.[0];
            if (!f) return;
            new maplibregl.Popup().setLngLat((f.geometry as { coordinates: number[] }).coordinates as [number, number]).setText(String(f.properties.label)).addTo(map);
            onSelect(String(f.properties.personId));
          });
          map.on('click', 'clusters', async (e) => {
            const f = e.features?.[0];
            if (!f) return;
            const zoom = await (map.getSource('pts') as import('maplibre-gl').GeoJSONSource).getClusterExpansionZoom(f.properties.cluster_id);
            map.easeTo({ center: (f.geometry as { coordinates: number[] }).coordinates as [number, number], zoom });
          });
          setReady(true);
        });
      } catch (e) { onFail((e as Error).message); }
    })();
    const t = setTimeout(() => { if (!mapRef.current?.isStyleLoaded()) onFail('Basemap did not load (offline?)'); }, 15000);
    return () => { cancelled = true; clearTimeout(t); mapRef.current?.remove(); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    const map = mapRef.current;
    if (!ready || !map) return;
    (map.getSource('pts') as import('maplibre-gl').GeoJSONSource).setData({ type: 'FeatureCollection', features: points.map((p) => ({ type: 'Feature', geometry: { type: 'Point', coordinates: [p.lon, p.lat] }, properties: { label: p.label, personId: p.personId, approximate: p.approximate, color: p.color } })) });
    (map.getSource('lines') as import('maplibre-gl').GeoJSONSource).setData({ type: 'FeatureCollection', features: lines.map((l) => ({ type: 'Feature', geometry: { type: 'LineString', coordinates: l.coords }, properties: { color: l.color } })) });
  }, [ready, points, lines]);

  return <div ref={ref} className="h-[520px] w-full overflow-hidden rounded-xl" role="region" aria-label="Interactive world map" />;
}
