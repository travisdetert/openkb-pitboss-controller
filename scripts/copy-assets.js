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
