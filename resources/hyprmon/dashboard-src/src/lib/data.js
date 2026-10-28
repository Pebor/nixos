/**
 * The report generator embeds the aggregates as JSON in the page, so this file
 * works from file:// with no fetch and no server. `sample.json` is only for
 * `npm run dev` while designing against synthetic data.
 */
export async function loadAggregates() {
  const node = document.getElementById('hyprmon-data');
  if (node && node.textContent.trim()) return JSON.parse(node.textContent);
  const res = await fetch('./sample.json');
  return res.json();
}

export function hm(minutes) {
  const total = Math.round(Number(minutes) || 0);
  if (total <= 0) return '0 min';
  if (total < 60) return `${total} min`;
  const h = Math.floor(total / 60);
  const m = total % 60;
  return m ? `${h} h ${m} min` : `${h} h`;
}

export function hms(minutes) {
  const total = Math.round(Number(minutes) || 0);
  return total >= 60 ? hm(total) : `${total} min`;
}
