import { readFileSync } from 'fs';

const table = readFileSync('docs/spec/05_07_Batch_Engine.md','utf8');
const matches = [...table.matchAll(/`(0x[0-9a-fA-F]{8})`/g)].map(m=>m[1]).sort();

const json = JSON.parse(readFileSync('selectors.json','utf8'));
const expected = (json.noBatch || []).sort();

if (JSON.stringify(matches) !== JSON.stringify(expected)) {
  console.error('selectors.json mismatch with docs table');
  process.exit(1);
}
