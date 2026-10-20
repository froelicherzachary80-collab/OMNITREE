/**
 * Small offline gazetteer for APPROXIMATE placement of place names that have no recorded
 * coordinates. Results are centroids (country/state/city level) and always labelled as
 * approximate — they never overwrite recorded coordinates.
 */
type Entry = [name: string, lat: number, lon: number, level: 'country' | 'region' | 'city'];

const ENTRIES: Entry[] = [
  // Countries
  ['united states', 39.8, -98.6, 'country'], ['usa', 39.8, -98.6, 'country'], ['canada', 56.1, -106.3, 'country'], ['mexico', 23.6, -102.5, 'country'],
  ['england', 52.4, -1.5, 'country'], ['scotland', 56.5, -4.2, 'country'], ['wales', 52.1, -3.8, 'country'], ['ireland', 53.4, -8.2, 'country'],
  ['northern ireland', 54.6, -6.7, 'country'], ['united kingdom', 54.0, -2.5, 'country'], ['france', 46.2, 2.2, 'country'], ['germany', 51.2, 10.4, 'country'],
  ['prussia', 53.0, 16.0, 'country'], ['netherlands', 52.1, 5.3, 'country'], ['belgium', 50.5, 4.5, 'country'], ['switzerland', 46.8, 8.2, 'country'],
  ['austria', 47.5, 14.6, 'country'], ['italy', 41.9, 12.6, 'country'], ['spain', 40.5, -3.7, 'country'], ['portugal', 39.4, -8.2, 'country'],
  ['norway', 60.5, 8.5, 'country'], ['sweden', 60.1, 18.6, 'country'], ['denmark', 56.3, 9.5, 'country'], ['finland', 61.9, 25.7, 'country'],
  ['poland', 51.9, 19.1, 'country'], ['czech republic', 49.8, 15.5, 'country'], ['bohemia', 49.8, 15.0, 'country'], ['hungary', 47.2, 19.5, 'country'],
  ['russia', 55.8, 37.6, 'country'], ['ukraine', 48.4, 31.2, 'country'], ['greece', 39.1, 21.8, 'country'], ['turkey', 39.0, 35.2, 'country'],
  ['israel', 31.0, 34.9, 'country'], ['egypt', 26.8, 30.8, 'country'], ['china', 35.9, 104.2, 'country'], ['japan', 36.2, 138.3, 'country'],
  ['india', 20.6, 79.0, 'country'], ['philippines', 12.9, 121.8, 'country'], ['australia', -25.3, 133.8, 'country'], ['new zealand', -40.9, 174.9, 'country'],
  ['south africa', -30.6, 22.9, 'country'], ['nigeria', 9.1, 8.7, 'country'], ['ghana', 7.9, -1.0, 'country'], ['brazil', -14.2, -51.9, 'country'],
  ['argentina', -38.4, -63.6, 'country'], ['chile', -35.7, -71.5, 'country'], ['cuba', 21.5, -77.8, 'country'], ['jamaica', 18.1, -77.3, 'country'],
  ['puerto rico', 18.2, -66.6, 'country'], ['lebanon', 33.9, 35.9, 'country'], ['syria', 34.8, 39.0, 'country'], ['iran', 32.4, 53.7, 'country'],
  ['korea', 36.5, 127.9, 'country'], ['vietnam', 14.1, 108.3, 'country'], ['lithuania', 55.2, 23.9, 'country'], ['latvia', 56.9, 24.6, 'country'],
  ['romania', 45.9, 25.0, 'country'], ['croatia', 45.1, 15.2, 'country'], ['slovakia', 48.7, 19.7, 'country'], ['iceland', 64.9, -19.0, 'country'],
  // US states / UK & other regions
  ['new york', 42.9, -75.5, 'region'], ['massachusetts', 42.3, -71.8, 'region'], ['pennsylvania', 40.9, -77.8, 'region'], ['virginia', 37.5, -78.9, 'region'],
  ['ohio', 40.3, -82.8, 'region'], ['illinois', 40.0, -89.2, 'region'], ['california', 37.2, -119.4, 'region'], ['texas', 31.0, -99.9, 'region'],
  ['new jersey', 40.1, -74.6, 'region'], ['connecticut', 41.6, -72.7, 'region'], ['maryland', 39.0, -76.8, 'region'], ['north carolina', 35.6, -79.4, 'region'],
  ['south carolina', 33.9, -80.9, 'region'], ['georgia', 32.7, -83.4, 'region'], ['kentucky', 37.5, -85.3, 'region'], ['tennessee', 35.9, -86.4, 'region'],
  ['michigan', 44.3, -85.4, 'region'], ['wisconsin', 44.6, -89.9, 'region'], ['minnesota', 46.3, -94.3, 'region'], ['iowa', 42.0, -93.5, 'region'],
  ['missouri', 38.4, -92.5, 'region'], ['indiana', 39.9, -86.3, 'region'], ['louisiana', 31.1, -92.0, 'region'], ['maine', 45.4, -69.2, 'region'],
  ['vermont', 44.1, -72.7, 'region'], ['new hampshire', 43.7, -71.6, 'region'], ['rhode island', 41.7, -71.5, 'region'], ['ontario', 50.0, -85.0, 'region'],
  ['quebec', 52.9, -73.5, 'region'], ['nova scotia', 45.0, -63.0, 'region'], ['yorkshire', 53.96, -1.08, 'region'], ['lancashire', 53.8, -2.6, 'region'],
  ['kent', 51.2, 0.7, 'region'], ['devon', 50.7, -3.8, 'region'], ['cornwall', 50.4, -4.9, 'region'], ['bavaria', 48.8, 11.5, 'region'],
  ['county cork', 51.9, -8.5, 'region'], ['ulster', 54.6, -7.0, 'region'], ['sicily', 37.6, 14.0, 'region'], ['silesia', 51.0, 17.0, 'region'],
  // Cities
  ['new york city', 40.71, -74.01, 'city'], ['brooklyn', 40.65, -73.95, 'city'], ['boston', 42.36, -71.06, 'city'], ['philadelphia', 39.95, -75.17, 'city'],
  ['chicago', 41.88, -87.63, 'city'], ['london', 51.51, -0.13, 'city'], ['paris', 48.86, 2.35, 'city'], ['berlin', 52.52, 13.40, 'city'],
  ['hamburg', 53.55, 9.99, 'city'], ['dublin', 53.35, -6.26, 'city'], ['edinburgh', 55.95, -3.19, 'city'], ['glasgow', 55.86, -4.25, 'city'],
  ['liverpool', 53.41, -2.98, 'city'], ['manchester', 53.48, -2.24, 'city'], ['amsterdam', 52.37, 4.90, 'city'], ['rome', 41.90, 12.50, 'city'],
  ['naples', 40.85, 14.27, 'city'], ['vienna', 48.21, 16.37, 'city'], ['warsaw', 52.23, 21.01, 'city'], ['krakow', 50.06, 19.94, 'city'],
  ['stockholm', 59.33, 18.07, 'city'], ['oslo', 59.91, 10.75, 'city'], ['copenhagen', 55.68, 12.57, 'city'], ['toronto', 43.65, -79.38, 'city'],
  ['montreal', 45.50, -73.57, 'city'], ['sydney', -33.87, 151.21, 'city'], ['melbourne', -37.81, 144.96, 'city'], ['jerusalem', 31.77, 35.21, 'city'],
  ['baltimore', 39.29, -76.61, 'city'], ['pittsburgh', 40.44, -79.99, 'city'], ['cleveland', 41.50, -81.69, 'city'], ['detroit', 42.33, -83.05, 'city'],
  ['st. louis', 38.63, -90.20, 'city'], ['new orleans', 29.95, -90.07, 'city'], ['san francisco', 37.77, -122.42, 'city'], ['los angeles', 34.05, -118.24, 'city'],
  ['york', 53.96, -1.08, 'city'], ['leeds', 53.80, -1.55, 'city'], ['belfast', 54.60, -5.93, 'city'], ['cork', 51.90, -8.47, 'city'],
];
const INDEX = new Map(ENTRIES.map((e) => [e[0], e]));

export interface Approx { lat: number; lon: number; level: Entry[3]; matched: string }

const norm = (s: string) => s.toLowerCase().replace(/[^a-z .'-]/g, '').trim();

/** Match the most specific comma-separated component found in the gazetteer (city > region > country). */
export function approximateLocation(place: string): Approx | undefined {
  const parts = place.split(',').map(norm).filter(Boolean);
  if (parts.length === 1 && parts[0] === 'new york') return { lat: 40.71, lon: -74.01, level: 'city', matched: 'new york city' };
  for (let i = 0; i < parts.length; i++) {
    let p = parts[i];
    // "New York, New York, USA" → the first "new york" is the city.
    if (p === 'new york' && parts[i + 1] === 'new york') p = 'new york city';
    const e = INDEX.get(p) ?? INDEX.get(p.replace(/^(county|city of|parish of) /, ''));
    if (e) return { lat: e[1], lon: e[2], level: e[3], matched: e[0] };
  }
  return undefined;
}
