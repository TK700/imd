// Copy shared assets into the static frontend dir before Tauri build.
const fs = require('fs');
const path = require('path');
const root = path.resolve(__dirname, '..');
const src = path.join(root, 'shared');
const dest = path.join(__dirname, 'src');

function copyDir(s, d) {
  fs.mkdirSync(d, { recursive: true });
  for (const e of fs.readdirSync(s)) {
    const sp = path.join(s, e), dp = path.join(d, e);
    if (fs.statSync(sp).isDirectory()) copyDir(sp, dp);
    else fs.copyFileSync(sp, dp);
  }
}
copyDir(path.join(src, 'preview'), path.join(dest, 'preview'));
copyDir(path.join(src, 'l10n'), path.join(dest, 'l10n'));
fs.copyFileSync(path.join(src, 'snippets.json'), path.join(dest, 'snippets.json'));
console.log('shared assets copied into src/');
