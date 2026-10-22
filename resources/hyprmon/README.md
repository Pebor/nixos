# hyprmon

A small, privacy-first activity logger for Hyprland. It records which window
has focus and for how long, lock/idle periods, media playback, Wi-Fi label and
basic resource gauges. It is one Python 3 file using only the standard library.

Requirements: Python 3.11+, Hyprland (for `hyprctl` and the event socket).
Optional sensors: `busctl` (MPRIS media), `loginctl` (lock state), `nmcli`
(Wi-Fi label). A missing helper disables that sensor and nothing else.

## Files

| File | Purpose |
|---|---|
| `hyprmon.py` | Daemon and CLI |
| `hyprmon.toml.example` | Configuration, with the default censor rules |
| `hyprmon.service` | systemd user unit |
| `test_hyprmon.py` | Self-tests (`python3 -m unittest -v test_hyprmon`) |

## Install

```sh
# 1. Store directory (created 0700 automatically on first write, but this makes it explicit)
install -d -m 0700 ~/.local/share/hyprmon

# 2. Program and config
install -Dm0755 hyprmon.py ~/.local/bin/hyprmon
install -Dm0600 hyprmon.toml.example ~/.config/hyprmon/hyprmon.toml
$EDITOR ~/.config/hyprmon/hyprmon.toml        # set [wifi_labels], review [[censor]]

# 3. Self-check before starting anything
~/.local/bin/hyprmon doctor

# 4. systemd user service
install -Dm0644 hyprmon.service ~/.config/systemd/user/hyprmon.service
systemctl --user daemon-reload
systemctl --user enable --now hyprmon.service
```

On NixOS, `~/.local/bin` is not on the default PATH for services, but the unit
uses an absolute `ExecStart`, and the unit's `Environment=PATH=` covers
`~/.nix-profile/bin` and `/etc/profiles/per-user/%u/bin`. If `hyprctl`,
`busctl`, `loginctl` or `nmcli` live elsewhere on your system, add that
directory to the unit's PATH.

## Wire up hypridle

Keep your existing `loginctl lock-session` call. Add the idle listener and the
control hooks to `~/.config/hypr/hypridle.conf`:

```ini
general {
    lock_cmd = pidof hyprlock || hyprlock
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd = hyprctl dispatch dpms on

    # Lock/unlock records. Check your hypridle version supports these keys
    # (`hypridle --help`, or the hypridle wiki). If it does not, skip them: the
    # daemon polls LockedHint every 30 s and records the transition itself.
    on_lock_cmd = hyprmon locked
    on_unlock_cmd = hyprmon unlocked
}

# Idle at 60 s of no input. Resume on the next input event.
listener {
    timeout = 60
    on-timeout = hyprmon idle
    on-resume = hyprmon active
}

# Your existing lock listener, unchanged.
listener {
    timeout = 300
    on-timeout = loginctl lock-session
}
```

`hyprmon idle` and `hyprmon active` only write the record and notify the daemon.
Nothing is recorded while idle. Both commands are cheap and safe to run when
the daemon is stopped.

## What is recorded

Every record is one JSON object per line, in a gzip file per local day:
`~/.local/share/hyprmon/events-YYYY-MM-DD.jsonl.gz` (mode 0600, directory 0700).

| `type` | Fields | Notes |
|---|---|---|
| `span` | `start_ts`, `end_ts`, `class`, `title`, `workspace`, `proc?`, `path?` | A focus span. `proc` = foreground command (hx, bash), `path` = a `[[path_label]]` label (never the raw cwd). Redacted spans carry `"redacted": true`. |
| `url` | `host`, `title?`, `channel?`, `browser?` | From the browser extension. `host` always; `title`/`channel` only when safe. |
| `media` | `player`, `status`, `title?`, `url_host?` | `title` and `url_host` only when safe (see privacy). |
| `wifi` | `label` | `ssid` only with `store_raw_ssid = true`. |
| `resources` | `cpu_pct`, `mem_available_mb`, `battery_pct`, `battery_power_w`, `battery_status` | Null when a source is missing. |
| `idle`, `active`, `lock`, `unlock` | `ts` only | Written by the CLI or the daemon. |

Records older than `retention_days` (default 14) are deleted at startup and at
each midnight.

## Process context (foot/hx, school-by-path)

For terminals and editors (`context_classes`), hyprmon follows the kernel's
foreground process group to find what the window is actually running and where:

- **`proc`** — the foreground command's name (`hx`, `bash`, `python3`, …). This
  is what turns a bare `foot` into `foot/hx` in the report, so a coding session
  is its own category instead of "terminal".
- **`path`** — a label from the first matching `[[path_label]]` regex against the
  process's working directory. So a terminal running `hx` inside
  `~/Documents/school` is labelled `school`, and the report counts it as school
  work. The raw path is never stored.

Turn it off with `context_enabled = false`. The doctor's `proc context` line
confirms `/proc` is readable.

## Browser extension (channels + domains)

MPRIS alone cannot tell you *which YouTube channel* you watched or that a tab
was on `fit.cvut.cz`. For that, install the companion WebExtension in Zen:

1. `about:debugging#/runtime/this-firefox` → *Load Temporary Add-on…* → pick
   `~/.local/share/hyprmon-extension/manifest.json` (or the copy in
   `resources/hyprmon/extension/`). Temporary add-ons reload after a browser
   restart; see the note below for a persistent install.
2. It reports the active tab (`host`, `title`, and the YouTube `channel` read
   off the page) to `http://127.0.0.1:4319/url` on every tab switch / title
   change. Nothing leaves your machine. Private/incognito tabs are skipped
   before anything is sent.

With it the report gains per-**channel** YouTube time and per-**site** tab time,
and a `cvut.cz` tab is classified as school by domain. Set `[url_source] token`
to a value (and put the same in `background.js`'s `TOKEN`) to require a token.

## Media services

`[media_services]` maps a player / url host to a service label so YouTube,
Spotify and the rest are counted separately in the report.

## Privacy

- **Censoring happens before writing.** Each focus span is checked against the
  `[[censor]]` rules when it closes. A `drop` span is never written. A `redact`
  span stores its replacement text instead of the title. The first matching
  rule wins.
- **Defaults drop private browsing.** Firefox and Zen private windows end with
  "Private Browsing", and `zen-beta`/`helium` windows with "Incognito" or
  "Private" in the title are dropped. Add your own rules with `[[censor]]`.
  Setting `censor = []` disables all rules. Don't do that unless you want
  private windows recorded.
- **Locked and idle periods record no window data.** Any span open when the
  session locks or goes idle is closed at that moment. A window that is
  focused during the lock gets its span starting at unlock, not earlier.
- **Media titles are not stored when they might be private.** Browsers
  announce private-window media with a placeholder title ("Zen is playing
  media"). Only the playback status is stored then. A media title is also not
  stored while any open window matches a drop rule. Only the host of a media
  URL is stored, never the path or query.
- **Wi-Fi is stored as a label.** Unmapped SSIDs become `other`. The raw SSID
  is not written unless you set `store_raw_ssid = true`.
- **Logs contain no window or media content.** Journal lines show counts,
  event names and error types. Titles are not written to stdout, stderr or the
  journal.
- **`status` shows no titles.** It prints the daemon state and the last five
  records with focus details withheld. To read your own data, open the store
  yourself, e.g. `zcat ~/.local/share/hyprmon/events-$(date +%F).jsonl.gz`.
- **The store is local and plain.** Anyone who can read your home directory
  can read it. Protect the account, not the file.

## Verify it works

Run these in order after installing. Each step should print what is described.

1. `hyprmon doctor` shows `[ok]` for `config`, `event socket` and `store`.
   `[warn]` lines for absent optional helpers are expected.
2. `systemctl --user status hyprmon` shows `active (running)`.
   `journalctl --user -u hyprmon -n 20` shows `connected to Hyprland event socket`.
3. `hyprmon status` shows `daemon: running`, `socket link: connected`, and
   `censor rules: 2` (or your count).
4. Focus a normal window for about 30 seconds, then switch to another. Run
   `hyprmon status` and check that the last five events include a `focus span`
   line of about the right duration.
5. Open a Firefox or Zen private window and focus it. Switch away. The
   `focused:` line should show `verdict drop`, and no new span line should
   appear for it.
6. `hyprmon locked`, wait 5 s, `hyprmon unlocked`. `status` should show a
   `lock` and an `unlock` line with matching times.
7. `hyprmon idle`, wait 5 s, `hyprmon active`. `status` should show `idle`
   and `active` lines.
8. Run `python3 -m unittest -v test_hyprmon` from the source directory. All
   tests should pass.

If `status` shows `daemon: not running`, check the journal first. If the store
is empty after several minutes, check that `doctor` shows the event socket as
connectable.

## Notes

- While the Hyprland socket is down, window records stop. Window state is
  dropped on disconnect, and the next connection re-reads the window list with
  `hyprctl`. Media, resource and Wi-Fi sampling continue.
- Single instance: a second `hyprmon run` exits with status 75 and names the
  running PID.
- SIGTERM and SIGINT close the open focus span and write it before exiting.
- Wi-Fi is read at most once a minute, including after focus changes, to avoid
  unnecessary `nmcli` runs.
- Uninstall: `systemctl --user disable --now hyprmon`, then remove
  `~/.local/bin/hyprmon`, `~/.config/systemd/user/hyprmon.service`, and
  optionally `~/.local/share/hyprmon`.
