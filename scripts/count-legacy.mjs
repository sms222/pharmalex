// Counts legacy content per Act. Usage: node scripts/count-legacy.mjs [path]
// path defaults to docs/pharmalex-legacy.html if present, else data.js.
// Accepts .js (defines window.X_DATA) or .html (inline <script> blocks).
import fs from 'node:fs';
import vm from 'node:vm';

const path = process.argv[2] ?? (fs.existsSync('docs/pharmalex-legacy.html') ? 'docs/pharmalex-legacy.html' : 'data.js');
const src = fs.readFileSync(path, 'utf8');
const code = path.endsWith('.html')
  ? [...src.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]).join('\n;')
  : src;

const win = {};
vm.runInNewContext(code, { window: win, document: { querySelectorAll: () => [], getElementById: () => null, querySelector: () => null }, localStorage: { getItem: () => null, setItem() {} }, setInterval() {}, clearInterval() {}, console });

const rows = Object.keys(win).filter(k => k.endsWith('_DATA')).map(k => {
  const d = win[k], n = d.notes ?? {};
  const items = s => (s ?? []).reduce((a, x) => a + (x.items?.length ?? 0), 0);
  return {
    act: k.replace('_DATA', ''),
    questions: d.questions?.length ?? 0,
    flashcards: d.flashcards?.length ?? 0,
    note_sections: (n.act?.length ?? 0) + (n.reg?.length ?? 0),
    note_items: items(n.act) + items(n.reg),
    warnings: n.warn?.length ?? 0,
    law_entries: d.law?.length ?? 0,
  };
});
const tot = rows.reduce((t, r) => { for (const k in r) if (k !== 'act') t[k] = (t[k] ?? 0) + r[k]; return t; }, { act: 'TOTAL' });
console.log('source:', path);
console.table([...rows, tot]);
