# herdr-last-used

*Which of these agents are alive, and which are just haunting you?*

Run [Herdr](https://herdr.dev) for a week and you have eleven agents open. Two
are doing real work. One is blocked on a question you have entirely forgotten
asking. The rest are dead — that task shipped on Tuesday — and the tab is still
there because closing it would have been a decision, and you were busy.

Congratulations: you have built a graveyard, and you are its groundskeeper.

The trouble is that Herdr draws all eleven exactly the same way. A dot, a name,
a status. Nothing separates the agent you were talking to ten minutes ago from
the one you abandoned mid-thought last week. So you keep the lot, because *what
if*, and the sidebar fills up with the digital equivalent of a drawer full of
cables you will never identify.

This plugin puts a time under each agent and colours it by age. **Green**, you
used it today. **Orange**, it has been a day. **Red**, it has been a week and
you both know how this ends.

Then one keypress filters the sidebar down to just the red ones, so you can bury
them properly and get on with your life. Tab anxiety: treated. FOMO: gently but
firmly overruled.

```
● proximie · 1              ● proximie · 1
  claude · working            claude · working
                              Last used 10:58        ← green, used today

● datalake · 1              ● datalake · 1
  claude · idle               claude · idle
                              Last used Sat 09:07    ← orange, 24h to a week

● old-spike · 1             ● old-spike · 1
  claude · idle               claude · idle
                              Last used 12 Aug       ← red, over a week
```

<img width="275" height="54" alt="image" src="https://github.com/user-attachments/assets/d177838d-0f68-405a-b171-cfa2a50089f6" />

The stamp is absolute and day-aware: `10:58` for today, `Sat 09:07` earlier in
the week, `12 Aug` beyond that. Herdr exposes no timestamp on an agent — only a
monotonic `state_change_seq` — so the plugin keeps its own clock.

## Requirements

- Herdr **0.7.5 or newer**. Three separate APIs set that floor: `agent.view.set`
  and `agent.view.clear`, one-shot `[[startup]]` hooks, and per-token `fg`
  styling in `ui.sidebar.agents.rows`. Developed and verified against 0.8.2.
- `jq`
- `python3` — for the sidebar filters, which use `agent.view.set`; that socket
  method has no CLI wrapper as of 0.8.2.
- Linux or macOS. The shell scripts target bash 3.2, which is what macOS ships.

## Install

```bash
herdr plugin install MorganCollins/herdr-last-used
```

Then restart herdr, or hand off to a new server. The sidebar rows and the
keybinding install themselves the first time the `[[startup]]` hook runs.

Herdr has no post-install hook — `[[build]]` commands run only for a GitHub
install, never for a linked plugin, and get no socket access — so startup is the
only place this can happen automatically. To skip the wait:

```bash
herdr plugin action invoke morgancollins.last-used.install-rows
```

That appends one marked block to your `config.toml`, backs the file up first,
and reloads. It refuses to touch a config that already defines
`ui.sidebar.agents.rows`, printing the snippet to merge by hand instead, and it
restores the backup if patching would leave the file unparseable.

**Your choice is remembered.** Run `uninstall-rows` and startup will not put the
block back on the next server start.

To develop against a local checkout:

```bash
git clone https://github.com/MorganCollins/herdr-last-used
herdr plugin link ./herdr-last-used
```

## Filtering the sidebar

Herdr's own `ui.agent_panel_scope` offers `current` and `all`, and
`ui.agent_panel_sort` offers `spaces` and `priority`. This plugin adds activity
as a third axis, which is what makes cleaning up abandoned sessions practical:
filter to `inactive`, then work down the list.

**`prefix+shift+F`** cycles through the bands:

```
all → active → stale → inactive → all
```

Each press shows a notification naming where you landed, because a filtered
sidebar and an empty one look alike. Herdr has no picker for plugin actions, so
one cycling key beats spending four on direct jumps — but the direct actions
exist if you would rather bind them:

```bash
herdr plugin action invoke morgancollins.last-used.show-active
herdr plugin action invoke morgancollins.last-used.show-stale
herdr plugin action invoke morgancollins.last-used.show-inactive
herdr plugin action invoke morgancollins.last-used.show-all      # clear
```

`active` sorts newest first; `stale` and `inactive` sort oldest first, so the
worst offenders are at the top. Sorting is on a hidden `$used_at` token holding
a zero-padded epoch, never on the visible label — token sorts are
lexicographic, where `Sat 09:07` would outrank `14:32`.

**Herdr keeps one agent view globally.** Setting a filter atomically replaces
whoever held it, so with two view-setting plugins the last to run wins, and this
plugin's startup replay takes the view on every server start. When that happens
you get a warning on stderr naming the source displaced, which lands in
`herdr plugin log list`. `show-all` clears only a view this plugin owns, so it
never steals one.

## Configure

Copy the example into the plugin's config directory:

```bash
cp assets/config.example.toml \
  "$(herdr plugin config-dir morgancollins.last-used)/config.toml"
```

| Key | Default | Meaning |
| --- | --- | --- |
| `fresh_max_hours` | `24` | Used within this many hours is **active** (green) |
| `stale_max_hours` | `168` | Beyond `fresh_max_hours` but within this is **stale** (orange); past it, **inactive** (red) |

Both must be whole numbers at the top level of the file, with
`0 < fresh < stale`. Anything else falls back to the defaults and says so on
stderr — a setting silently ignored is the worst outcome for a config file.

Colours are not here. They belong in your Herdr config, on the `fg` fields of
the block `install-rows` wrote, because that is where Herdr expects styling to
live: metadata reporters supply values only.

## Why three tokens

Herdr's row layouts style each token occurrence in *your* config, and reporters
supply values only — so a single token cannot change colour. The plugin instead
sets exactly one of `$used_fresh`, `$used_stale` or `$used_old` and clears the
other two. All three sit on one row with different `fg`, and because empty
tokens and their separators disappear, you see one value in one colour.

That same shape makes filtering trivial: "show me only the stale agents" is an
`exists` test on `$used_stale`.

## How it works

`pane.agent_status_changed` and `pane.agent_detected` both run `stamp.sh`. It
records the triggering pane's time, then re-reports the token for **every** live
agent.

Re-stamping everything on each event is deliberate. A token is a static string
once reported, so nothing would move an agent from green to orange on its own.
Re-rendering the whole list means the bands and the day-aware format correct
themselves whenever anything in the herd changes state — no background daemon,
which plugin v1 has no mechanism for anyway.

The trade-off is real and worth stating plainly: nothing re-renders until the
herd next changes state, so on a completely idle herd the drift is unbounded,
not small. Both the colour and the label go stale — a stamp rendered `14:32`
still reads `14:32` tomorrow, when it should read `Sat 14:32`. A herd left alone
over a weekend will look fresher than it is. The `[[startup]]` hook re-renders
on every server start, and the `refresh` action forces it on demand:

```bash
herdr plugin action invoke morgancollins.last-used.refresh
```

Times are keyed by pane ID **and** the pane's terminal ID, because pane IDs are
reusable slots. A new agent landing on a closed pane's ID is treated as
first-seen rather than inheriting the previous occupant's age.

Only one run renders at a time. Herdr spawns a process per event and
`pane.agent_detected` fires alongside `pane.agent_status_changed`, so overlapping
runs are normal rather than exotic. A run that cannot take the lock appends its
event to a queue for the holder to fold in, so concurrent events are not lost.
Two honest limitations of that queue:

- An event queued *after* the holder has already claimed the queue waits for the
  next run. If no further event ever arrives, the `[[startup]]` hook drains it at
  the next server start. This is asserted by a test rather than left implied.
- The queue is capped at 500 entries. Past that, events are dropped with a
  message on stderr rather than growing a file without limit.

A lock is broken if its owning process is gone, or if it has been held far
longer than a run can legitimately take — a PID outlives its process and can be
reused, and without that backstop a recycled PID would wedge the plugin
permanently.

State lives in `$HERDR_PLUGIN_STATE_DIR`, which in practice is
`~/.local/state/herdr/plugins/morgancollins.last-used/` — useful when debugging:
`stamps` holds the remembered times, `filter` the chosen band, `rows` whether
the config block is installed, `seq` the report counter.

## Layout

```
herdr-plugin.toml       manifest — must stay at the repo root
src/
  lib.sh                shared helpers: formatting, bands, settings, paths
  stamp.sh              the event hook; stamps and re-renders every live agent
  startup.sh            installs rows once, stamps, then replays the filter
  filter.sh             installs an agent view for one activity band
  cycle-filter.sh       advances the band and reports where you landed
  install-rows.sh       patches the sidebar layout and keybinding into your config
  uninstall-rows.sh     removes that block again
  socket_request.py     one-shot socket client for agent.view.set/clear
  config_toml.py        TOML queries grep cannot do (see install-rows)
assets/
  config.snippet.toml   the rows and keybinding install-rows writes
  config.example.toml   threshold settings to copy into the config dir
test/
  run.sh                the suite
  fake-herdr            stub for the herdr CLI, logs every invocation
  socket_recorder.py    real unix socket that records one request
  check_manifest.py     manifest and asset consistency checks
  fixtures-agent-list.json  a response captured from a real herdr
```

Manifest commands are written as `src/...` because Herdr resolves relative
plugin commands from the plugin root. The scripts locate themselves rather than
relying on cwd, so they also run fine by hand.

## Tests

```bash
bash test/run.sh
```

217 tests, ~15s, no Herdr server required. The `herdr` CLI is the plugin's only
system boundary, so it is the only thing stubbed; the socket path is tested
against a real unix socket, so the request framing is genuinely exercised.
Everything else — the formatting, the banding, the state pruning, the config
patching — runs for real and is asserted on its output.

`test/fixtures-agent-list.json` is a response **captured from a real
`herdr agent list`** rather than a shape written by hand. That matters: the stub
originally invented the envelope, putting `agents` at the top level where herdr
actually returns `{"id":…,"result":{"agents":[…]}}`. The whole suite passed
against a contract that did not exist while the plugin failed on every real
event.

Concurrency, locking, herdr CLI failure injection, malformed agent-list output,
hostile config values and DST boundaries all have cases. `TZ` is pinned so date
assertions are machine-independent. The suite also asserts that the set of
checks that ran matches the set the file defines — a subshell aborting before
its assertions would otherwise contribute nothing and leave the run green, and a
count alone can be balanced out by a check that ran twice.

## Caveats

- Only live agent panes are decorated. There is no history for agents that no
  longer exist, and Herdr does not restore token metadata across a restart — the
  plugin's own state file is what carries real ages through one.
- A pane already running when the plugin is first installed has no recorded
  time, so it is stamped as first-seen rather than given invented history.
- `install-rows` adds `state_text` to the layout. Herdr's default rows show no
  state text at all, so without it there is no "idle" for the stamp to sit under.
- `rows` is a full replacement, not an addition, so once installed your agent
  sidebar is pinned to this plugin's layout. If herdr changes its defaults you
  will not see the change until you re-run `install-rows`.
- The colours live inside the managed block, which is the block `uninstall-rows`
  deletes. Uninstalling warns when the block has been edited, but your palette
  goes with it — recover from the timestamped backup.

## Licence

MIT
