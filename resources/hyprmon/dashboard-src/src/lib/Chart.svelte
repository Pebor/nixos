<script>
  import { Chart } from 'chart.js/auto';
  import { onMount, onDestroy } from 'svelte';

  let { config, height = 280 } = $props();
  let canvas;
  let chart;
  let host;
  let observer;

  onMount(() => {
    Chart.defaults.color = '#b3c2d6';
    Chart.defaults.borderColor = 'rgba(70, 96, 124, .35)';
    Chart.defaults.font.family = 'ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';
    Chart.defaults.font.size = 12;
    // A fractional devicePixelRatio (Hyprland scaling 1.25/1.5) leaves the canvas
    // backing store at a non-integer size and the labels render soft. Round it up.
    Chart.defaults.devicePixelRatio = Math.max(1, Math.ceil(window.devicePixelRatio || 1));
    chart = new Chart(canvas, config);

    // The card is laid out after the first paint; without an explicit resize the
    // backing store keeps the pre-layout width and the text renders blurry.
    requestAnimationFrame(() => chart?.resize());
    observer = new ResizeObserver(() => chart?.resize());
    observer.observe(host);
  });

  // A parent toggle (e.g. share/minutes) swaps the whole config; the chart has to
  // be told, otherwise the button changes state but nothing on screen moves.
  $effect(() => {
    const next = config;
    if (!chart || !next) return;
    chart.config.data = next.data;
    chart.config.options = next.options;
    chart.update();
  });

  onDestroy(() => {
    observer?.disconnect();
    chart?.destroy();
    chart = undefined;
  });
</script>

<div class="chart" bind:this={host} style="height:{height}px">
  <canvas bind:this={canvas}></canvas>
</div>

<style>
  .chart { position: relative; width: 100%; }
</style>
