import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, dirname, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

// The page's ES modules keep the Swift layering (docs/features/web-page/design.md §4):
// device/ imports nothing of ours; families never import each other; an
// internal/ folder is imported only from inside the folder that holds it.
const WEB = resolve(dirname(fileURLToPath(import.meta.url)), '../../Sources/Baguette/Resources/Web');

function modules(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    return statSync(path).isDirectory() ? modules(path) : name.endsWith('.js') ? [path] : [];
  });
}

/** Every module under the layered folders, with the files it imports (web-root relative). */
function imports() {
  const layered = ['device', 'families', 'panels', 'wire', 'page', 'capture']
    .map((folder) => join(WEB, folder)).filter((dir) => { try { return statSync(dir).isDirectory(); } catch { return false; } });
  return layered.flatMap(modules).map((file) => ({
    file: relative(WEB, file),
    imports: [...readFileSync(file, 'utf8').matchAll(/^\s*import\s[^'"]*['"](\.[^'"]+)['"]/gm)]
      .map((m) => relative(WEB, resolve(dirname(file), m[1]))),
  }));
}

const top = (path) => path.split(sep)[0];

test('should keep device/ free of imports from any other folder', () => {
  for (const { file, imports: used } of imports().filter((m) => top(m.file) === 'device')) {
    for (const path of used) assert.equal(top(path), 'device', `${file} imports ${path}`);
  }
});

test('should keep each family from importing another', () => {
  // families/families.js, the one list of families, is the only file that names them all.
  const inAFamily = (m) => top(m.file) === 'families' && m.file.split(sep).length > 2;
  for (const { file, imports: used } of imports().filter(inAFamily)) {
    const family = file.split(sep)[1];
    for (const path of used.filter((p) => top(p) === 'families' && p.split(sep).length > 2)) {
      assert.equal(path.split(sep)[1], family, `${file} imports another family's ${path}`);
    }
  }
});

test('should import an internal/ module only from inside the folder that holds it', () => {
  for (const { file, imports: used } of imports()) {
    for (const path of used) {
      const at = path.split(sep).indexOf('internal');
      if (at < 0) continue;
      const owner = path.split(sep).slice(0, at).join(sep);
      assert.ok(file.startsWith(owner + sep), `${file} reaches into ${path}`);
    }
  }
});

/** The devices list, which filters by kind — the user's chosen platform and reality. */
const LIST = ['devices-list.js', 'device-filter.js'];

test('should leave reading a device\'s kind to Families on the device page', () => {
  // The device page tells its device's roles; only families/families.js reads
  // `kind` to pick a family. (The devices list filters by kind — the user's
  // own choice of platform and reality — which is data, not behaviour.)
  const page = [join(WEB, 'page/device-page.js'), ...imports().map((m) => join(WEB, m.file))]
    .filter((file) => !file.endsWith(join('families', 'families.js')))
    .filter((file) => !LIST.some((name) => file.endsWith(join('page', name))));
  for (const file of page) {
    const reads = readFileSync(file, 'utf8').match(/\.reality\b|kind\.platform\b|\bdevicePlatform\b|\bdeviceMode\b/g);
    assert.equal(reads, null, `${relative(WEB, file)} reads a device's kind: ${reads}`);
  }
});
