import { parseGedcom } from '../genealogy/gedcom/parser';
import { FamilyGraph } from '../genealogy/graph/familyGraph';
import { FAMILY_GED } from './fixtures/synthetic';

export function loadFamily(text = FAMILY_GED) {
  const parsed = parseGedcom(text, { workspaceId: 'ws1', importId: 'imp1' });
  const graph = new FamilyGraph(parsed.persons, parsed.families);
  const byGed = (x: string) => parsed.persons.find((p) => p.gedcomId === x)!.id;
  return { parsed, graph, byGed };
}
