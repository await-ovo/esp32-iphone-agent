import { build } from 'esbuild';
import stdlib from 'node-stdlib-browser';
import { createRequire } from 'node:module';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);
const photonDir = path.dirname(require.resolve('@silvia-odwyer/photon/package.json'));
const wasm = await readFile(path.join(photonDir, 'photon_rs_bg.wasm'));
await mkdir(path.join(root, 'build'), { recursive: true });
await mkdir(path.join(root, 'Resources/Midscene'), { recursive: true });
await writeFile(path.join(root, 'build/globals.mjs'), `
import { Buffer } from ${JSON.stringify(stdlib.buffer)};
import process from ${JSON.stringify(stdlib.process)};
export { Buffer, process };
`);
const result = await build({
  absWorkingDir: root,
  entryPoints: ['runtime/main.ts'],
  outfile: 'Resources/Midscene/runtime.js',
  bundle: true,
  platform: 'browser',
  format: 'iife',
  target: 'safari18',
  minify: true,
  legalComments: 'linked',
  metafile: true,
  inject: [path.join(root, 'build/globals.mjs')],
  define: {
    global: 'globalThis',
    PHOTON_WASM_BASE64: JSON.stringify(wasm.toString('base64')),
    'import.meta.url': JSON.stringify('https://unused.invalid/photon.js'),
  },
  plugins: [{ name: 'ios-browser-dependencies', setup(builder) {
    builder.onResolve({ filter: /^node:|^(assert|buffer|events|fs|path|os|util|stream|crypto|process|url|http|https|zlib|tty|vm)(\/.*)?$/ }, async args => {
      const name = args.path.replace(/^node:/, '');
      if (['fs', 'fs/promises', 'child_process', 'net'].includes(name)) {
        return { path: name, namespace: 'unavailable' };
      }
      if (stdlib[name]) return builder.resolve(stdlib[name], { resolveDir: root, kind: args.kind });
    });
    builder.onResolve({ filter: /^sharp$/ }, () => ({ path: 'sharp', namespace: 'unavailable' }));
    builder.onLoad({ filter: /.*/, namespace: 'unavailable' }, args => ({
      // Enumerate properties so named ESM imports remain present and fail loudly
      // if a path accidentally reaches a Node-only feature.
      contents: `const fail = () => { throw Error(${JSON.stringify(`Unavailable in WKWebView: ${args.path}`)}); };
module.exports = Object.fromEntries(${JSON.stringify(['existsSync', 'mkdirSync', 'readFileSync', 'writeFileSync', 'appendFileSync', 'createWriteStream', 'openSync', 'closeSync', 'readSync', 'statSync', 'unlinkSync', 'readFile', 'writeFile', 'appendFile', 'mkdir', 'rename', 'unlink', 'copyFile', 'stat', 'readdir', 'execFile', 'spawn', 'createServer'])}.map(name => [name, fail]));`,
      loader: 'js',
    }));
  } }],
});
const inputs = Object.keys(result.metafile.inputs);
if (inputs.some(name => /midscene-edge-audit|packages\/(core|shared)\/src/.test(name))) {
  throw Error('Unexpected repository-source input; the runtime must use published npm packages');
}
await writeFile(path.join(root, 'build/bundle-meta.json'), JSON.stringify(result.metafile));
console.log(`Official Midscene 1.16.1 bundled for WKWebView; ${inputs.length} modules, no embedded Node.`);
