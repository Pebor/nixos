# hyprmon dashboard (Svelte 5 + Chart.js)

The report generator embeds `aggregates.json` into a single HTML file, so the
published `dashboard.html` works from `file://` — no server, no fetch, and no
data ever leaves the machine.

## Rebuild

```bash
cd resources/hyprmon/dashboard-src
npm install
npm run build
cp dist/index.html ../dashboard.html   # the committed template
```

`vite-plugin-singlefile` inlines JS and CSS into one file; the report injects
`<script id="hyprmon-data" type="application/json">…</script>` right after
`<body>`, and `src/lib/data.js` reads it.

## Dev

`npm run dev` falls back to `./sample.json` (synthetic aggregates) — never point
it at real data outside the T14.

Charts: Chart.js (doughnut / stacked bar / horizontal bar) plus a CSS-grid
heatmap; the palette mirrors the Python report's Tableau hues, lifted for the
near-black canvas.
