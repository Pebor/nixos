<script>
  import { Chart } from 'chart.js/auto';
  import { onMount, onDestroy } from 'svelte';

  let { config, height = 280 } = $props();
  let canvas;
  let chart;

  onMount(() => {
    Chart.defaults.color = '#b3c2d6';
    Chart.defaults.borderColor = 'rgba(70, 96, 124, .35)';
    Chart.defaults.font.family = 'ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';
    Chart.defaults.font.size = 11;
    chart = new Chart(canvas, config);
  });

  onDestroy(() => {
    chart?.destroy();
    chart = undefined;
  });
</script>

<div class="chart" style="height:{height}px">
  <canvas bind:this={canvas}></canvas>
</div>

<style>
  .chart { position: relative; width: 100%; }
</style>
