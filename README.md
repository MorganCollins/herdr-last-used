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
cp config.example.toml "$(herdr plugin config-dir morgancollins.last-used)/config.toml"
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
saved in the plugin's state directory and reapplied by the `[[startup]]` hook.

## How it works

`pane.agent_status_changed` and `pane.agent_detected` both run `stamp.sh`. It
records the triggering pane's time in `$HERDR_PLUGIN_STATE_DIR/stamps`, then
re-reports the token for **every** live agent.

Re-stamping everything on each event is deliberate. A token is a static string
once reported, so nothing would move an agent from green to orange on its own.
Re-rendering the whole list means the buckets and the day-aware format correct
themselves whenever anything in the herd changes state — no background daemon
to supervise, which Herdr's plugin v1 has no mechanism for anyway.

The trade-off: if the entire herd sits idle overnight with no events at all, a
row can stay green a little past the 24h mark until the next event. With
thresholds this coarse that is rarely visible, and the `refresh` action forces
it:

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

## Licence

MIT

## Tests

```bash
bash test.sh
```

60 tests, no Herdr server required. The `herdr` CLI is the plugin's only system
boundary, so it is the only thing stubbed (`test/fake-herdr` records every
invocation). The socket path is tested against a real unix socket rather than a
mock, so the request framing is genuinely exercised. Everything else — the
formatting, the bucketing, the state pruning, the config patching — runs for
real and is asserted on its output.
