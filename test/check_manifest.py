#!/usr/bin/env python3
"""Manifest assertions that are awkward to express inline in shell."""
import os
import sys
import tomllib

# Names Herdr accepts in a manifest [[events]] `on` field, from
# PLUGIN_HOOK_EVENT_KINDS in src/api/schema/events.rs.
HOOK_EVENTS = {
    "workspace.created", "workspace.updated", "workspace.closed",
    "workspace.renamed", "workspace.moved", "workspace.reordered",
    "workspace.focused", "worktree.created", "worktree.opened",
    "worktree.removed", "tab.created", "tab.closed", "tab.renamed",
    "tab.moved", "tab.focused", "pane.created", "pane.closed",
    "pane.focused", "pane.moved", "pane.exited", "pane.agent_detected",
    "pane.agent_status_changed",
}

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
manifest = tomllib.load(open(os.path.join(ROOT, "herdr-plugin.toml"), "rb"))
check = sys.argv[1]

if check == "events":
    bad = [e["on"] for e in manifest.get("events", []) if e["on"] not in HOOK_EVENTS]
    print(",".join(bad) or "none")
elif check == "commands":
    missing = [
        item["command"][1]
        for key in ("startup", "events", "actions", "panes")
        for item in manifest.get(key, [])
        if not os.path.exists(os.path.join(ROOT, item["command"][1]))
    ]
    print(",".join(missing) or "none")
elif check == "action-ids":
    ids = [a["id"] for a in manifest["actions"]]
    print("dupes" if len(ids) != len(set(ids)) else "unique")
elif check == "required-keys":
    missing = [k for k in ("id", "name", "version", "min_herdr_version") if k not in manifest]
    print(",".join(missing) or "none")
elif check == "rows-colours":
    import json
    rows = tomllib.load(open(sys.argv[2], "rb"))["ui"]["sidebar"]["agents"]["rows"]
    print(json.dumps(rows[2], separators=(",", ":")))
elif check == "rows-count":
    rows = tomllib.load(open(sys.argv[2], "rb"))["ui"]["sidebar"]["agents"]["rows"]
    print(len(rows))
elif check == "ui-preserved":
    ui = tomllib.load(open(sys.argv[2], "rb"))["ui"]
    print(ui["agent_panel_scope"], ui["toast"]["delivery"])
else:
    sys.exit(f"unknown check: {check}")
