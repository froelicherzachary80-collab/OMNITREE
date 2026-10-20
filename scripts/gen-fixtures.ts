// Writes synthetic (fictional) fixture files for e2e tests and manual trials.
import { writeFileSync } from 'node:fs';
import { FAMILY_GED, syntheticPanel, to23andMeFormat, toAncestryFormat } from '../src/tests/fixtures/synthetic';
const panel = syntheticPanel(20000, 11);
writeFileSync('e2e/fixtures/family.ged', FAMILY_GED);
writeFileSync('e2e/fixtures/synthetic-ancestrydna.txt', toAncestryFormat(panel));
writeFileSync('e2e/fixtures/synthetic-23andme.txt', to23andMeFormat(panel.slice(3000)));
