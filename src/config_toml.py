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
        # Walk defensively: any level may hold a non-table value in a config a
        # human wrote, and a traceback here would be read as "no".
        node = data
        for key in ("ui", "sidebar", "agents"):
            if not isinstance(node, dict):
                node = None
                break
            node = node.get(key)
        print("yes" if isinstance(node, dict) and "rows" in node else "no")
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
