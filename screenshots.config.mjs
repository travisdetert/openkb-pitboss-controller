// Shot manifest for the desktop app. One command regenerates every image in
// docs/screenshots/ from a recorded cook, so a UI change and its documentation
// stay in step and nothing has to be staged by hand.
//
//   npm run screenshots
//
// Each shot replays the same cook file at the same rate and captures after the
// same delay, so the same inputs produce the same output every run. `click`
// presses elements by id before capturing, which is how the modals are shot.
export default {
  // A real recorded cook, replayed. Committed fixture rather than a live grill:
  // a screenshot that needs the hardware powered on is one nobody can reproduce.
  replay: 'docs/fixtures/cook-sample.jsonl',
  rate: 400,          // samples/second — 400 fills the curve in a few seconds
  settleMs: 13_000,   // let the chart fill before capturing
  outDir: 'docs/screenshots',
  // Names are distinct from the hand-made shots that predate this manifest
  // (dashboard.png = the between-cooks view, wizard.png = first run). Those are
  // not yet reproducible; do not overwrite them from here.
  shots: [
    { name: 'live-dashboard', theme: 'dark',
      caption: 'The live dashboard: grill curve, component activity, and a probe panel per probe with its cook estimate.' },
    { name: 'live-dashboard-light', theme: 'light',
      caption: 'The same view in the light theme — every colour comes from the token layer, including the canvas charts.' },
    { name: 'cut-picker', theme: 'dark', click: ['p2CutBtn'],
      caption: 'Choosing what is on a probe: 45 cuts grouped by category, each with its suggested target.' },
    { name: 'cut-detail', theme: 'dark', click: ['p2CutBtn', 'cutItem0'],
      caption: 'One cut, and only that cut: its targets labelled by kind, the USDA floor, its methods, and its usual grill temperature.' },
  ],
};
