// hyprmon tab reporter — sends the active tab (host, title, YouTube channel)
// to the local hyprmon daemon's loopback endpoint. No data ever leaves the box.
//
// The daemon stores the host always, and the title/channel only after the same
// censor rules that guard window titles. Private/incognito tabs are skipped
// entirely here, so they never reach the daemon at all.
//
// Works in Firefox/Zen (browser.*) and Chromium/Helium (chrome.*) via the shim.

const API = (typeof browser !== "undefined") ? browser : chrome;
const ENDPOINT = "http://127.0.0.1:4319/url";
const TOKEN = ""; // set if you put a token in hyprmon.toml [url_source]
const BROWSER_NAME = (typeof browser !== "undefined") ? "zen" : "helium";
const HEARTBEAT_MIN = 1;

// Throttle: rapid tab switches should not spam the daemon.
let lastSent = 0;
let pending = null;

function hostOf(url) {
  try { return new URL(url).hostname; } catch (e) { return ""; }
}

async function youtubeChannel(tabId) {
  // Read the channel name straight off the YouTube page DOM. Falls back to ""
  // if the page has not loaded the owner block yet.
  try {
    const res = await API.scripting.executeScript({
      target: { tabId },
      func: () => {
        const sel = [
          "ytd-watch-metadata ytd-channel-name #text a",
          "#owner #channel-name a",
          "ytd-video-owner-renderer #channel-name a",
          "#channel-name a",
        ];
        for (const s of sel) {
          const el = document.querySelector(s);
          if (el && el.textContent.trim()) return el.textContent.trim();
        }
        return "";
      },
    });
    return (res && res[0] && res[0].result) || "";
  } catch (e) {
    return "";
  }
}

async function collectAndSend() {
  let tabs;
  try {
    tabs = await API.tabs.query({ active: true, lastFocusedWindow: true });
  } catch (e) {
    return;
  }
  const tab = tabs && tabs[0];
  if (!tab || !tab.url || tab.incognito || tab.id == null) return;
  const host = hostOf(tab.url);
  if (!host) return;
  let channel = "";
  if (/youtube\.com|youtu\.be/.test(host)) {
    channel = await youtubeChannel(tab.id);
  }
  const payload = {
    url: tab.url,
    host,
    title: tab.title || "",
    channel,
    browser: BROWSER_NAME,
  };
  try {
    await fetch(ENDPOINT, {
      method: "POST",
      headers: Object.assign({ "Content-Type": "application/json" },
                            TOKEN ? { "X-Hyprmon-Token": TOKEN } : {}),
      body: JSON.stringify(payload),
      keepalive: true,
    });
    lastSent = Date.now();
  } catch (e) {
    /* daemon not running: ignore */
  }
}

function schedule() {
  if (pending) clearTimeout(pending);
  const wait = Math.max(0, 500 - (Date.now() - lastSent));
  pending = setTimeout(() => { pending = null; collectAndSend(); }, wait);
}

// Report on activation, title/url change, window focus change, and heartbeat.
API.tabs.onActivated.addListener(schedule);
API.tabs.onUpdated.addListener((id, info) => {
  if (info.title || info.url || info.status === "complete") schedule();
});
if (API.windows && API.windows.onFocusChanged) {
  API.windows.onFocusChanged.addListener((winId) => {
    if (winId !== API.windows.WINDOW_ID_NONE) schedule();
  });
}

if (API.alarms) {
  API.alarms.onAlarm.addListener((a) => { if (a.name === "hb") schedule(); });
  API.alarms.create("hb", { periodInMinutes: HEARTBEAT_MIN });
}

// First report shortly after the browser starts.
setTimeout(collectAndSend, 1500);
