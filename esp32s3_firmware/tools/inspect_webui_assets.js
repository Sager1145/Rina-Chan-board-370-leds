const fs = require('fs');
const zlib = require('zlib');

const sourcePath = process.argv[2] || 'webui/index.html';
let html;
if (sourcePath.endsWith('.gz')) {
  html = zlib.gunzipSync(fs.readFileSync(sourcePath)).toString('utf8');
} else {
  html = fs.readFileSync(sourcePath, 'utf8');
}

const script = (html.match(/<script>([\s\S]*)<\/script>/i) || ['', ''])[1];
function snippet(pattern, length = 500) {
  const index = script.indexOf(pattern);
  if (index < 0) return null;
  return script.slice(index, index + length);
}
function escaped(text) {
  if (text == null) return null;
  return text.replace(/[^\x20-\x7E\n\r\t]/g, ch => '\\u' + ch.charCodeAt(0).toString(16).padStart(4, '0'));
}

const h1 = (html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i) || ['', null])[1];
const title = (html.match(/<title[^>]*>([\s\S]*?)<\/title>/i) || ['', null])[1];
console.log(JSON.stringify({
  sourcePath,
  bytes: Buffer.byteLength(html),
  title: escaped(title),
  h1: escaped(h1),
  colorInfo: escaped(snippet('const color_info', 800)),
  voiceData: escaped(snippet('const voice_data', 800)),
  musicData: escaped(snippet('const music_data', 800)),
  defaultFaces: escaped(snippet('DEFAULT_FACES', 800)),
}, null, 2));
