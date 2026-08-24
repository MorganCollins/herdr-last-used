# herdr-last-used

A [Herdr](https://herdr.dev) plugin that shows when each live agent was last
active, colour-coded by age, and lets you filter the Agent sidebar down to one
activity bucket.

```
● proximie · backend        ● proximie · backend
  claude · idle               claude · idle
                              14:32                 <- green, used today

● datalake · dbt            ● datalake · dbt
  codex · idle                codex · idle
                              Sat 09:07             <- orange, 24h to 1 week

● old-spike · main          ● old-spike · main
  claude · idle               claude · idle
                              12 Aug                <- red, over a week
```

The stamp is absolute and day-aware: `14:32` for today, `Sat 09:07` earlier in
the week, `12 Aug` beyond that.

## Why three tokens

Herdr metadata reporters supply values only — styling is declared per token
occurrence in your own config. So a single token cannot change colour. Instead
the plugin sets exactly one of `$used_fresh`, `$used_stale`, or `$used_old` and
clears the other two. All three sit on one sidebar row with different `fg`
values, and because empty tokens and their separators disappear, you see one
value in one colour.

That same one-of-three shape is what makes filtering trivial: "show me only the
stale agents" is an `exists` test on `$used_stale`.

## Requirements

- Herdr 0.7.5 or newer (`ui.sidebar.agents.rows` landed in 0.7.4, per-token
  `fg` styling in 0.7.5)
- `jq`
- `python3` — only for the sidebar filters, which use `agent.view.set`; that
  socket method has no CLI wrapper as of Herdr 0.8.2
- Linux or macOS. The shell scripts target bash 3.2, which is what macOS ships.

## Install

```bash
herdr plugin install MorganCollins/herdr-last-used
herdr plugin action invoke morgancollins.last-used.install-rows
```

`install-rows` appends a marked block to your `config.toml` defining the row
layout, backs the file up first, and reloads the config. It refuses to touch a
config that already has its own `[ui.sidebar.agents]` and prints the snippet to
merge by hand instead. `uninstall-rows` removes the block again.

To develop against a local checkout:

```bash
git clone https://github.com/MorganCollins/herdr-last-used
herdr plugin link ./herdr-last-used
```

## Configure

Copy the example into the plugin's config directory:

```bash
cp assets/config.example.toml "$(herdr plugin config-dir morgancollins.last-used)/config.toml"
```

| Key | Default | Meaning |
| --- | --- | --- |
| `fresh_max_hours` | `24` | Used within this many hours is **active** (green) |
| `stale_max_hours` | `168` | Beyond `fresh_max_hours` but within this is **stale** (orange); past it, **inactive** (red) |

Colours are not in this file. They belong in your Herdr config, on the `fg`
fields of the block `install-rows` wrote — that is where Herdr expects styling
to live.

## Filter the sidebar by activity

Herdr's built-in `ui.agent_panel_scope` only offers `current` and `all`. These
actions add activity as a third axis, which makes cleaning up abandoned
sessions straightforward: filter to `inactive`, then work down the list.

```bash
herdr plugin action invoke morgancollins.last-used.show-active
herdr plugin action invoke morgancollins.last-used.show-stale
herdr plugin action invoke morgancollins.last-used.show-inactive
herdr plugin action invoke morgancollins.last-used.show-all      # clear
```

Worth binding to keys:

```toml
[[keys.command]]
key = "prefix+alt+1"
type = "plugin_action"
command = "morgancollins.last-used.show-active"
description = "agents: active"

[[keys.command]]
key = "prefix+alt+2"
type = "plugin_action"
command = "morgancollins.last-used.show-stale"
description = "agents: stale"

[[keys.command]]
key = "prefix+alt+3"
type = "plugin_action"
command = "morgancollins.last-used.show-inactive"
description = "agents: inactive"

[[keys.command]]
key = "prefix+alt+0"
type = "plugin_action"
command = "morgancollins.last-used.show-all"
description = "agents: all"
```

An agent view is transient and dies with the server, so the chosen filter is
saved in the plugin's state directory and replayed by the `[[startup]]` hook.

**Herdr keeps one agent view globally.** Setting a filter atomically replaces
whoever held it, so if you run another view-setting plugin, the last one to run
wins — and this plugin's startup replay will take the view from it on every
server start. When that happens you get a warning on stderr naming the source
that was displaced, which lands in `herdr plugin log list`. `show-all` clears
only a view this plugin owns, so it will not steal one from someone else.

Filtered buckets are sorted by a hidden `$used_at` token holding a zero-padded
epoch, not by the visible label — labels sort lexicographically, where
`Sat 09:07` would outrank `14:32`. `active` sorts newest first; `stale` and
`inactive` sort oldest first, so the worst offenders are at the top.

## Layout

```
herdr-plugin.toml       manifest — must stay at the repo root
src/
  lib.sh                shared helpers: formatting, bucketing, settings, paths
  stamp.sh              the event hook; stamps and re-renders every live agent
  startup.sh            stamps, then replays the saved filter, in that order
  filter.sh             installs an agent view for one activity bucket
  install-rows.sh       patches the sidebar layout into your herdr config
  uninstall-rows.sh     removes that block again
  socket_request.py     one-shot socket client for agent.view.set/clear
  config_toml.py        TOML queries grep cannot do (see install-rows)
assets/
  rows.snippet.toml     the sidebar rows install-rows.sh writes
  config.example.toml   threshold settings to copy into the config dir
test/
  run.sh                the suite
  fake-herdr            stub for the herdr CLI, logs every invocation
  socket_recorder.py    real unix socket that records one request
  check_manifest.py     manifest assertions
```

Manifest commands are written as `src/...` because Herdr resolves relative
plugin commands from the plugin root. The scripts locate themselves rather than
relying on cwd, so they also run fine by hand.

## How it works

`pane.agent_status_changed` and `pane.agent_detected` both run `stamp.sh`. It
records the triggering pane's time in `$HERDR_PLUGIN_STATE_DIR/stamps`, then
re-reports the token for **every** live agent.

Re-stamping everything on each event is deliberate. A token is a static string
once reported, so nothing would move an agent from green to orange on its own.
Re-rendering the whole list means the buckets and the day-aware format correct
themselves whenever anything in the herd changes state — no background daemon
to supervise, which Herdr's plugin v1 has no mechanism for anyway.

The trade-off is real and worth stating plainly: nothing re-renders until the
herd next changes state, so on a completely idle herd the drift is unbounded,
not small. Both the colour and the label go stale — a stamp rendered `14:32`
still reads `14:32` tomorrow, when it should read `Sat 14:32`, and `14:32`
unambiguously means today. A herd left alone over a weekend will look fresher
than it is. The `[[startup]]` hook re-renders on every server start, and the
`refresh` action forces it on demand:

```bash
herdr plugin action invoke morgancollins.last-used.refresh
```

Stamps are keyed by pane ID and pruned to live panes on every run, so closed
panes drop out. The state file outlives a server restart, which means real ages
survive it even though Herdr does not restore token metadata itself.

## Caveats

- Only live agent panes are decorated. There is no history for agents that no
  longer exist.
- A pane already running when the plugin is first installed has no recorded
  time, so it is stamped as first-seen rather than given invented history.
- `install-rows` adds `state_text` to the layout. Herdr's default rows do not
  show state text at all, so without it there is no "idle" for the stamp to sit
  under.
- `rows` is a full replacement, not an addition, so once installed your agent
  sidebar is pinned to this plugin's layout. If herdr changes its default rows
  you will not see the change until you re-run `install-rows`.
- The colours live inside the block `install-rows` manages, which is the block
  `uninstall-rows` deletes. Uninstalling warns when the block has been edited,
  but your palette goes with it — recover from the timestamped backup.
- Timestamps are keyed by pane id plus the pane's terminal id, because pane ids
  are reusable slots. A new agent landing on a closed pane's id is treated as
  first-seen rather than inheriting the previous occupant's age.

## Licence

MIT

## Tests

```bash
bash test/run.sh
```

134 tests, no Herdr server required. The `herdr` CLI is the plugin's only system
boundary, so it is the only thing stubbed (`test/fake-herdr` records every
invocation). The socket path is tested against a real unix socket rather than a
mock, so the request framing is genuinely exercised. Everything else — the
formatting, the bucketing, the state pruning, the config patching — runs for
real and is asserted on its output.

Concurrency, herdr CLI failures, malformed agent-list output, hostile config
values, and DST boundaries all have cases. `TZ` is pinned so date assertions are
machine-independent. The suite also asserts its own check count, because a
subshell that aborts before its assertions would otherwise contribute nothing
and leave the run green.
