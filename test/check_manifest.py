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
elif check == "token-contract":
    # The token names are the whole cross-process contract: lib.sh reports them
    # and the user's config references them. A rename on one side alone renders
    # nothing at all, with no error anywhere, so pin them together.
    lib = open(os.path.join(ROOT, "src", "lib.sh")).read()
    reported = []
    for line in lib.splitlines():
        for name in ("TOKEN_FRESH", "TOKEN_STALE", "TOKEN_OLD"):
            if line.startswith(f"{name}="):
                reported.append("$" + line.split("=", 1)[1].strip().strip('"'))
    snippet = tomllib.load(open(os.path.join(ROOT, "assets", "rows.snippet.toml"), "rb"))
    rows = snippet["ui"]["sidebar"]["agents"]["rows"]
    referenced = [
        entry["token"] if isinstance(entry, dict) else entry
        for row in rows for entry in row
        if (entry["token"] if isinstance(entry, dict) else entry).startswith("$")
    ]
    if sorted(reported) == sorted(referenced) and len(reported) == len(referenced):
        print("match")
    else:
        print(f"reported={sorted(reported)} referenced={sorted(referenced)}")
elif check == "ui-preserved":
    ui = tomllib.load(open(sys.argv[2], "rb"))["ui"]
    print(ui["agent_panel_scope"], ui["toast"]["delivery"])
else:
    sys.exit(f"unknown check: {check}")
