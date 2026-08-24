#!/usr/bin/env python3
"""Send one JSON request to the Herdr socket and print the response line.

agent.view.set / agent.view.clear have no CLI wrapper in Herdr 0.8.2, so the
filter actions talk to the socket directly. The protocol is newline-delimited
JSON with no handshake: write one request line, read one line back.
"""
import json
import os
import socket
import sys

TIMEOUT_SECONDS = 10


def main() -> int:
    path = os.environ.get("HERDR_SOCKET_PATH")
    if not path:
        print("HERDR_SOCKET_PATH is not set", file=sys.stderr)
        return 1
    if len(sys.argv) < 2:
        print("usage: socket_request.py '<json request>'", file=sys.stderr)
        return 1

    request = sys.argv[1].strip()
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(TIMEOUT_SECONDS)
            client.connect(path)
            client.sendall(request.encode() + b"\n")
            buffer = b""
            while b"\n" not in buffer:
                chunk = client.recv(65536)
                if not chunk:
                    break
                buffer += chunk
    except OSError as error:
        print(f"socket error: {error}", file=sys.stderr)
        return 1

    line = buffer.split(b"\n", 1)[0].decode(errors="replace")
    if not line:
        print("herdr closed the connection without responding", file=sys.stderr)
        return 1

    print(line)

    # Decide on the parsed error field, not on whether the text "error" appears
    # somewhere in the payload — a workspace or label may legitimately be named
    # that, and this is the only failure signal the shell layer gets.
    try:
        response = json.loads(line)
    except json.JSONDecodeError:
        print("herdr sent a response that is not JSON", file=sys.stderr)
        return 1

    error = response.get("error") if isinstance(response, dict) else None
    if error:
        detail = error if isinstance(error, str) else json.dumps(error)
        print(f"herdr returned an error: {detail}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
