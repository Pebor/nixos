<script>
  import { onMount } from 'svelte';
  import Chart from './lib/Chart.svelte';
  import { loadAggregates, hm } from './lib/data.js';

  let data = $state(null);
  let error = $state('');
  let mixMode = $state('share'); // 'share' | 'absolute'

  onMount(async () => {
    try {
      data = await loadAggregates();
    } catch (e) {
      error = e?.message || String(e);
    }
  });

  // Same hues as the Python report, lifted a little for a near-black canvas.
  const COLORS = {
    school: '#5b8ac9', coding: '#69b85f', youtube: '#ef6b6b', music: '#f5a04a',
    messaging: '#bd8fb7', browsing: '#84c9c4', terminal: '#b08874', other: '#b9b1ad'
  };
  const EXTRA = ['#e9c94e', '#ff9da7', '#8fd0c9', '#d97fa3', '#7aa6d6', '#7fc47a', '#e87b7b'];
  const WIFI_COLORS = ['#8dd3c7', '#fdb462', '#bebada', '#fb8072', '#80b1d3', '#ffffb3', '#b3de69', '#fccde5'];

  const order = $derived(data?.categories?.order ?? []);
  const days = $derived(data?.days ?? []);
  const totals = $derived(data?.totals ?? {});
  const colors = $derived.by(() => {
    const map = {};
    let k = 0;
    for (const c of order) map[c] = COLORS[c] || EXTRA[k++ % EXTRA.length];
    return map;
  });

  const catRows = $derived(
    order
      .map((c) => ({ cat: c, minutes: totals.category_minutes?.[c] ?? 0, percent: totals.category_percent?.[c] ?? 0 }))
      .filter((r) => r.minutes > 0)
      .sort((a, b) => b.minutes - a.minutes)
  );

  const kpis = $derived([
    { label: 'Aktivita', value: hm(totals.active_minutes), tone: 'cyan' },
    { label: 'Media', value: hm(totals.media_minutes), tone: 'rose' },
    { label: 'AFK', value: hm(totals.afk_minutes), tone: 'muted' },
    { label: 'Zamčeno', value: hm(totals.locked_minutes), tone: 'muted' },
    { label: 'Idle span', value: hm(totals.idle_span_minutes), tone: 'muted' }
  ]);

  const donutConfig = $derived({
    type: 'doughnut',
    data: {
      labels: catRows.map((r) => r.cat),
      datasets: [{
        data: catRows.map((r) => Math.round(r.minutes)),
        backgroundColor: catRows.map((r) => colors[r.cat]),
        borderWidth: 0,
        hoverOffset: 8
      }]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      cutout: '62%',
      animation: { animateRotate: true, duration: 800 },
      plugins: {
        legend: { display: false },
        tooltip: { callbacks: { label: (c) => ` ${c.label}: ${hm(c.parsed)}` } }
      }
    }
  });

  const mixConfig = $derived.by(() => {
    const share = mixMode === 'share';
    const cats = order.filter((c) => days.some((d) => (data.per_day?.[d]?.[c] ?? 0) > 0));
    return {
      type: 'bar',
      data: {
        labels: days.map((d) => d.slice(5)),
        datasets: cats.map((c) => ({
          label: c,
          stack: 'mix',
          backgroundColor: colors[c],
          borderRadius: 2,
          data: days.map((d) => {
            const m = data.per_day?.[d]?.[c] ?? 0;
            const active = data.per_day_totals?.[d]?.active_minutes ?? 0;
            return share && active > 0 ? (m / active) * 100 : m;
          })
        }))
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: { duration: 600 },
        scales: {
          x: { stacked: true, grid: { display: false } },
          y: {
            stacked: true,
            max: share ? 100 : undefined,
            ticks: { callback: (v) => (share ? `${Math.round(v)} %` : hm(v)) }
          }
        },
        plugins: {
          legend: { display: false },
          tooltip: {
            callbacks: {
              label: (c) => ` ${c.dataset.label}: ${share ? `${c.parsed.y.toFixed(0)} %` : hm(c.parsed.y)}`
            }
          }
        }
      }
    };
  });

  const mediaConfig = $derived({
    type: 'bar',
    data: {
      labels: days.map((d) => d.slice(5)),
      datasets: [
        { label: 'Aktivita', data: days.map((d) => data.per_day_totals?.[d]?.active_minutes ?? 0), backgroundColor: '#4e79a7', borderRadius: 3 },
        { label: 'Media playing', data: days.map((d) => data.per_day_totals?.[d]?.media_minutes ?? 0), backgroundColor: '#ef6b6b', borderRadius: 3 }
      ]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      scales: {
        x: { grid: { display: false } },
        y: { ticks: { callback: (v) => hm(v) } }
      },
      plugins: {
        legend: { position: 'bottom', labels: { boxWidth: 10, boxHeight: 10, padding: 14 } },
        tooltip: { callbacks: { label: (c) => ` ${c.dataset.label}: ${hm(c.parsed.y)}` } }
      }
    }
  });

  const appsConfig = $derived.by(() => {
    const rows = (data.top_apps ?? []).slice(0, 10);
    return {
      type: 'bar',
      data: {
        labels: rows.map((r) => r.app),
        datasets: [{ data: rows.map((r) => r.minutes), backgroundColor: rows.map((r) => colors[r.category] || '#888'), borderRadius: 3 }]
      },
      options: {
        indexAxis: 'y',
        responsive: true,
        maintainAspectRatio: false,
        scales: {
          x: { ticks: { callback: (v) => hm(v) } },
          y: { grid: { display: false } }
        },
        plugins: { legend: { display: false }, tooltip: { callbacks: { label: (c) => ` ${hm(c.parsed.x)}` } } }
      }
    };
  });

  const wifiRows = $derived(
    Object.entries(data?.wifi_minutes ?? {})
      .map(([label, minutes]) => ({ label, minutes }))
      .sort((a, b) => b.minutes - a.minutes)
  );

  const wifiConfig = $derived({
    type: 'doughnut',
    data: {
      labels: wifiRows.map((r) => r.label),
      datasets: [{
        data: wifiRows.map((r) => Math.round(r.minutes)),
        backgroundColor: wifiRows.map((_, i) => WIFI_COLORS[i % WIFI_COLORS.length]),
        borderWidth: 0,
        hoverOffset: 6
      }]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      cutout: '58%',
      plugins: {
        legend: { display: false },
        tooltip: { callbacks: { label: (c) => ` ${c.label}: ${hm(c.parsed)}` } }
      }
    }
  });

  const heatMax = $derived.by(() => {
    let max = 1;
    for (const d of days) for (const v of data.per_day_hour?.[d] ?? []) max = Math.max(max, v);
    return max;
  });

  function heatColor(v) {
    if (!v) return 'rgba(22, 32, 46, .55)';
    const t = Math.min(1, v / heatMax);
    return `rgba(34, 211, 238, ${0.16 + 0.74 * t})`;
  }

  const windowLabel = $derived(
    data ? (data.window.from === data.window.to ? data.window.from : `${data.window.from} → ${data.window.to}`) : ''
  );
</script>

<main class="wrap">
  {#if error}
    <p class="error">Data se nepodařilo načíst: {error}</p>
  {:else if !data}
    <p class="loading">načítám…</p>
  {:else}
    <header class="hero">
      <p class="kicker">hyprmon · osobní aktivita</p>
      <h1>{windowLabel}</h1>
      <p class="meta">
        {data.window.days} dní · {data.window.timezone} · vygenerováno {data.generated_at}
      </p>
    </header>

    <section class="kpis">
      {#each kpis as k}
        <div class="kpi {k.tone}">
          <span class="kpi-label">{k.label}</span>
          <strong>{k.value}</strong>
        </div>
      {/each}
    </section>

    <div class="grid">
      <article class="card">
        <div class="card-head">
          <h2>Kategorie</h2>
          <span class="tag">podíl aktivního času</span>
        </div>
        <Chart config={donutConfig} height={250} />
        <ul class="legend">
          {#each catRows as r}
            <li>
              <i style="background:{colors[r.cat]}"></i>
              <span class="name">{r.cat}</span>
              <b>{hm(r.minutes)}</b>
              <span class="pct">{r.percent.toFixed(0)} %</span>
            </li>
          {/each}
        </ul>
      </article>

      <article class="card">
        <div class="card-head">
          <h2>Denní mix</h2>
          <div class="seg">
            <button class:on={mixMode === 'share'} onclick={() => (mixMode = 'share')}>podíly</button>
            <button class:on={mixMode === 'absolute'} onclick={() => (mixMode = 'absolute')}>minuty</button>
          </div>
        </div>
        <Chart config={mixConfig} height={250} />
        <ul class="legend inline">
          {#each order as c}
            <li><i style="background:{colors[c]}"></i><span class="name">{c}</span></li>
          {/each}
        </ul>
      </article>

      <article class="card wide">
        <div class="card-head">
          <h2>Aktivita po hodinách</h2>
          <span class="tag">30 min = plná barva</span>
        </div>
        <div class="heat">
          <div class="heat-hours">
            {#each Array(24) as _, h}<span>{h % 3 === 0 ? h : ''}</span>{/each}
          </div>
          {#each days as d}
            <div class="heat-row">
              <span class="heat-day">{d.slice(5)}</span>
              <div class="heat-cells">
                {#each Array(24) as _, h}
                  <span
                    class="heat-cell"
                    style="background:{heatColor(data.per_day_hour?.[d]?.[h] ?? 0)}"
                    title="{d} {String(h).padStart(2, '0')}:00 — {hm(data.per_day_hour?.[d]?.[h] ?? 0)}"
                  ></span>
                {/each}
              </div>
            </div>
          {/each}
        </div>
      </article>

      <article class="card">
        <div class="card-head"><h2>Media vs aktivita</h2></div>
        <Chart config={mediaConfig} height={250} />
      </article>

      <article class="card">
        <div class="card-head"><h2>Top aplikace</h2></div>
        <Chart config={appsConfig} height={280} />
      </article>

      <article class="card">
        <div class="card-head"><h2>Wi-Fi</h2></div>
        {#if wifiRows.length}
          <Chart config={wifiConfig} height={200} />
          <ul class="legend">
            {#each wifiRows as r, i}
              <li><i style="background:{WIFI_COLORS[i % WIFI_COLORS.length]}"></i><span class="name">{r.label}</span><b>{hm(r.minutes)}</b></li>
            {/each}
          </ul>
        {:else}
          <p class="empty">žádná wifi data</p>
        {/if}
      </article>

      {#if data.media_minutes?.per_service && Object.keys(data.media_minutes.per_service).length}
        <article class="card">
          <div class="card-head"><h2>Media podle služby</h2></div>
          <ul class="rows">
            {#each Object.entries(data.media_minutes.per_service).sort((a, b) => b[1] - a[1]) as [name, m]}
              <li><span class="name">{name}</span><b>{hm(m)}</b></li>
            {/each}
          </ul>
        </article>
      {/if}

      {#if data.channels?.length}
        <article class="card">
          <div class="card-head"><h2>YouTube kanály</h2></div>
          <ul class="rows">
            {#each data.channels.slice(0, 8) as ch}
              <li><span class="name">{ch.channel}</span><b>{hm(ch.playing_minutes)}</b><span class="pct">tab {hm(ch.tab_minutes)}</span></li>
            {/each}
          </ul>
        </article>
      {/if}

      {#if data.hosts?.length}
        <article class="card">
          <div class="card-head"><h2>Nejvíc času na webu</h2></div>
          <ul class="rows">
            {#each data.hosts.slice(0, 8) as h}
              <li><span class="name">{h.host}</span><b>{hm(h.tab_minutes)}</b></li>
            {/each}
          </ul>
        </article>
      {/if}
    </div>

    <details class="health">
      <summary>Data health</summary>
      <ul>
        <li>soubory: {data.health.files_read?.length ?? 0}</li>
        <li>invalidní eventy: {data.health.invalid_events ?? 0}</li>
        <li>neklasifikovaný čas: {(data.health.span_unclassified_percent_time ?? 0).toFixed(1)} %</li>
        <li>kategorie: {data.health.category_source ?? '—'}</li>
      </ul>
    </details>
  {/if}
</main>

<style>
  .wrap { max-width: 1180px; margin: 0 auto; padding: 28px 20px 64px; }

  .hero { margin-bottom: 20px; }
  .kicker { margin: 0 0 4px; font-size: 11px; letter-spacing: .16em; text-transform: uppercase; color: var(--muted); }
  h1 { margin: 0 0 6px; font-size: 26px; color: var(--head); letter-spacing: -.01em; }
  .meta { margin: 0; color: var(--dim); font-size: 13px; }

  .kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 10px; margin-bottom: 16px; }
  .kpi {
    background: var(--surface); border: 1px solid var(--line); border-radius: 12px;
    padding: 12px 14px; display: flex; flex-direction: column; gap: 2px;
  }
  .kpi-label { font-size: 11px; letter-spacing: .1em; text-transform: uppercase; color: var(--muted); }
  .kpi strong { font-size: 21px; font-weight: 650; color: var(--head); }
  .kpi.cyan { border-color: rgba(34, 211, 238, .35); }
  .kpi.rose { border-color: rgba(251, 113, 133, .35); }

  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: 14px; }
  .card { background: var(--surface); border: 1px solid var(--line); border-radius: 14px; padding: 14px 16px 16px; }
  .card.wide { grid-column: 1 / -1; }
  .card-head { display: flex; align-items: center; gap: 10px; margin-bottom: 10px; }
  h2 { margin: 0; font-size: 14px; font-weight: 650; color: var(--head); }
  .tag { margin-left: auto; font-size: 11px; color: var(--muted); }

  .seg { margin-left: auto; display: inline-flex; border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
  .seg button { background: var(--surface-2); border: 0; color: var(--muted); font-size: 11.5px; padding: 4px 10px; cursor: pointer; }
  .seg button + button { border-left: 1px solid var(--line); }
  .seg button.on { background: rgba(96, 165, 250, .18); color: #bfdbfe; }

  .legend { list-style: none; margin: 10px 0 0; padding: 0; display: grid; gap: 4px; }
  .legend.inline { grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); }
  .legend li { display: flex; align-items: center; gap: 8px; font-size: 12.5px; color: var(--dim); }
  .legend i { width: 10px; height: 10px; border-radius: 3px; flex: 0 0 auto; }
  .legend .name { flex: 1 1 auto; }
  .legend b { color: var(--text); font-weight: 600; font-variant-numeric: tabular-nums; }
  .legend .pct { color: var(--muted); width: 42px; text-align: right; font-variant-numeric: tabular-nums; }

  .rows { list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; }
  .rows li { display: flex; align-items: baseline; gap: 10px; font-size: 12.5px; color: var(--dim); border-bottom: 1px solid rgba(42, 58, 77, .5); padding-bottom: 5px; }
  .rows li:last-child { border-bottom: 0; }
  .rows .name { flex: 1 1 auto; color: var(--text); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .rows b { font-variant-numeric: tabular-nums; }
  .rows .pct { color: var(--muted); font-size: 11.5px; }

  .heat { display: grid; gap: 3px; }
  .heat-hours { display: grid; grid-template-columns: repeat(24, 1fr); gap: 3px; margin-left: 44px; color: var(--muted); font-size: 9.5px; text-align: center; }
  .heat-row { display: grid; grid-template-columns: 40px 1fr; gap: 4px; align-items: center; }
  .heat-day { font-size: 10.5px; color: var(--muted); font-variant-numeric: tabular-nums; }
  .heat-cells { display: grid; grid-template-columns: repeat(24, 1fr); gap: 3px; }
  .heat-cell { display: block; height: 18px; border-radius: 3px; transition: transform .1s; }
  .heat-cell:hover { transform: scale(1.15); outline: 1px solid var(--line-strong); }

  .health { margin-top: 18px; color: var(--muted); font-size: 12px; }
  .health summary { cursor: pointer; }
  .health ul { margin: 8px 0 0; padding-left: 18px; }

  .loading, .error { color: var(--dim); padding: 24px 0; }
  .error { color: #fda4af; }
  .empty { color: var(--muted); font-size: 12.5px; }

  @media (max-width: 640px) {
    .wrap { padding: 18px 12px 48px; }
    h1 { font-size: 20px; }
    .grid { grid-template-columns: 1fr; }
    .heat-cells { gap: 2px; }
    .heat-cell { height: 14px; }
  }
</style>
