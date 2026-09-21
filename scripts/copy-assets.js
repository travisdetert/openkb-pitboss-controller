// Copy renderer static assets (html, css) into dist/renderer alongside the
// compiled renderer.js, so index.html can reference ./renderer.js / ./styles.css.
const fs = require('fs');
const path = require('path');

const srcDir = path.join(__dirname, '..', 'src', 'renderer');
const outDir = path.join(__dirname, '..', 'dist', 'renderer');

fs.mkdirSync(outDir, { recursive: true });
for (const file of ['index.html', 'styles.css']) {
  fs.copyFileSync(path.join(srcDir, file), path.join(outDir, file));
  console.log(`copied ${file} -> dist/renderer/`);
}

// The cooking knowledge base is read at runtime, not compiled in, so it has to
// ship inside dist/ (which is what goes into the asar). One file is the source
// of truth for both apps — see ADR 0007 and scripts/sync-data.mjs.
const dataOut = path.join(__dirname, '..', 'dist', 'data');
fs.mkdirSync(dataOut, { recursive: true });
for (const file of ['cooking.json']) {
  fs.copyFileSync(path.join(__dirname, '..', 'data', file), path.join(dataOut, file));
  console.log(`copied ${file} -> dist/data/`);
}

// Shared logic for the renderer, which is a plain browser script rather than a
// module (see the note at the top of renderer.ts). Instead of keeping a second
// copy of the estimator there — the exact duplication ADR 0007 exists to avoid —
// the compiled CommonJS is wrapped in an IIFE that hands back its exports as one
// global. Both files are type-only importers, so there is no `require` to
// resolve; the check below fails the build loudly if that ever stops being true.
const shared = [
  { file: 'estimate.js', global: 'PBEstimate' },
  { file: 'cooking.js', global: 'PBCooking' },
  { file: 'protocol.js', global: 'PBProtocol' },
];
const sharedOut = path.join(__dirname, '..', 'dist', 'renderer');
for (const { file, global } of shared) {
  const src = fs.readFileSync(path.join(__dirname, '..', 'dist', 'shared', file), 'utf8');
  if (/\brequire\s*\(/.test(src)) {
    throw new Error(`dist/shared/${file} has a runtime require() — it can no longer be `
      + `wrapped for the renderer. Keep shared/ modules type-only importers, or `
      + `introduce a real bundler.`);
  }
  const wrapped = `// GENERATED from dist/shared/${file} by scripts/copy-assets.js — do not edit.\n`
    + `var ${global} = (function () {\n  var exports = {};\n${src}\n  return exports;\n})();\n`;
  fs.writeFileSync(path.join(sharedOut, `${global}.js`), wrapped);
  console.log(`wrapped shared/${file} -> dist/renderer/${global}.js`);
}

// Menu-bar (tray) template icons live in build/ but must ship inside dist/ so
// they're available at runtime in the packaged app (dist is in the asar).
const buildDir = path.join(__dirname, '..', 'build');
const assetsDir = path.join(__dirname, '..', 'dist', 'assets');
fs.mkdirSync(assetsDir, { recursive: true });
for (const file of ['trayTemplate.png', 'trayTemplate@2x.png']) {
  const from = path.join(buildDir, file);
  if (fs.existsSync(from)) {
    fs.copyFileSync(from, path.join(assetsDir, file));
    console.log(`copied ${file} -> dist/assets/`);
  } else {
    console.warn(`(skip) ${file} not found in build/ — run "npm run icon"`);
  }
}
