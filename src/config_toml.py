#!/usr/bin/env python3
"""TOML queries the shell layer needs. grep cannot see TOML structure: the same
table can be spelled [ui.sidebar.agents], dotted under [ui.sidebar], quoted, or
inline, and mistaking any of those for absent means writing a duplicate key."""
import sys
import tomllib


def main() -> int:
    check, path = sys.argv[1], sys.argv[2]
    try:
        with open(path, "rb") as handle:
            data = tomllib.load(handle)
    except FileNotFoundError:
        print("missing", file=sys.stderr)
        return 2
    except tomllib.TOMLDecodeError as error:
        print(f"invalid TOML: {error}", file=sys.stderr)
        return 3

    if check == "parses":
        print("ok")
        return 0

    if check == "has-agent-rows":
        agents = data.get("ui", {}).get("sidebar", {}).get("agents", {})
        print("yes" if isinstance(agents, dict) and "rows" in agents else "no")
        return 0

    if check == "row-tokens":
        # Every $token referenced by the installed layout, in order.
        rows = data["ui"]["sidebar"]["agents"]["rows"]
        names = [
            entry["token"] if isinstance(entry, dict) else entry
            for row in rows
            for entry in row
        ]
        print(" ".join(n for n in names if n.startswith("$")))
        return 0

    if check == "coloured-tokens":
        # $tokens that carry an explicit non-empty fg, in order.
        rows = data["ui"]["sidebar"]["agents"]["rows"]
        print(" ".join(
            entry["token"]
            for row in rows
            for entry in row
            if isinstance(entry, dict) and entry.get("token", "").startswith("$")
            and entry.get("fg")
        ))
        return 0

    sys.exit(f"unknown check: {check}")


if __name__ == "__main__":
    sys.exit(main())
