import { expect, test } from '@playwright/test';
import path from 'node:path';

const fx = (f: string) => path.join(process.cwd(), 'e2e', 'fixtures', f);

test('workspace → GEDCOM import → tree → relationship → OmniAI → DNA', async ({ page }) => {
  await page.goto('/');
  await page.getByTestId('ws-name').fill('E2E Family');
  await page.getByTestId('create-ws').click();
  await page.getByTestId('ged-file').setInputFiles(fx('family.ged'));
  await expect(page.getByTestId('ged-preview')).toContainText('17');
  await page.getByTestId('commit-import').click();
  await expect(page.getByText('family.ged').first()).toBeVisible();

  await page.goto('/#/relationships');
  await page.getByTestId('rel-a').click();
  await page.getByTestId('rel-a').fill('Arthur');
  await page.getByRole('option').first().click();
  await page.getByTestId('rel-b').click();
  await page.getByTestId('rel-b').fill('Ivy');
  await page.getByRole('option').first().click();
  await expect(page.getByTestId('rel-result').first()).toContainText('first cousin once removed');

  await page.goto('/#/tree');
  await page.getByTestId('jump').click();
  await page.getByTestId('jump').fill('Arthur');
  await page.getByRole('option').first().click();
  await page.getByRole('button', { name: 'Set as home person' }).click();
  await page.getByTestId('edit-person').click();
  await page.getByTestId('given').fill('Arthur James');
  await page.getByTestId('save-person').click();
  await expect(page.getByRole('heading', { name: 'Arthur James Thornwood', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Undo' }).click();
  await expect(page.getByRole('heading', { name: 'Arthur Thornwood', exact: true })).toBeVisible();

  await page.goto('/#/ai');
  await page.getByTestId('ai-input').fill('Show my parents and grandparents.');
  await page.getByRole('button', { name: 'Ask' }).click();
  await expect(page.getByText(/2 parent\(s\) and 2 grandparent/)).toBeVisible();

  await page.goto('/#/dna');
  await page.getByLabel('Kit owner (required)').click();
  await page.getByLabel('Kit owner (required)').fill('Arthur');
  await page.getByRole('option').first().click();
  await page.getByTestId('dna-file').setInputFiles(fx('synthetic-ancestrydna.txt'));
  await expect(page.getByText('AncestryDNA').first()).toBeVisible();
  await page.getByRole('checkbox').first().check();
  await page.getByTestId('save-kit').click();
  await expect(page.getByRole('heading', { name: 'DNA kits' })).toBeVisible();
});
