const fs = require('fs');

const html = fs.readFileSync('webui/index.html', 'utf8');
const beforeScript = html.split(/<script/i)[0] || '';
const ids = [];
let m;

const idRe = /\bid\s*=\s*(['"])(.*?)\1/gi;
while ((m = idRe.exec(beforeScript))) {
  ids.push(m[2]);
}

const seenIds = new Set();
const duplicateIds = [];
for (const id of ids) {
  if (seenIds.has(id) && duplicateIds.indexOf(id) < 0) {
    duplicateIds.push(id);
  }
  seenIds.add(id);
}

const script = (html.match(/<script>([\s\S]*)<\/script>/i) || ['', ''])[1];
const functionCounts = new Map();
const fnRe = /(?:^|\n)\s*(?:async\s+)?function\s+([A-Za-z_$][\w$]*)\s*\(/g;
while ((m = fnRe.exec(script))) {
  functionCounts.set(m[1], (functionCounts.get(m[1]) || 0) + 1);
}
const duplicateFunctions = Array.from(functionCounts.entries())
  .filter((entry) => entry[1] > 1)
  .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));

const apiPaths = Array.from(new Set(
  Array.from(script.matchAll(/['"`](\/api\/[^'"`?\s)]+)[^'"`]*['"`]/g), (hit) => hit[1])
)).sort();

console.log(JSON.stringify({
  domIds: ids.length,
  uniqueDomIds: seenIds.size,
  duplicateDomIds: duplicateIds,
  duplicateFunctions,
  apiPaths,
}, null, 2));
