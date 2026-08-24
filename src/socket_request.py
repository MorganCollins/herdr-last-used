#!/usr/bin/env python3
"""Send one JSON request to the Herdr socket and print the response line.

agent.view.set / agent.view.clear have no CLI wrapper in Herdr 0.8.2, so the
filter actions talk to the socket directly. The protocol is newline-delimited
JSON with no handshake: write one request line, read one response line.
"""
import json
import os
import socket
import sys


def main() -> int:
    path = os.environ.get("HERDR_SOCKET_PATH")
    if not path:
        print("HERDR_SOCKET_PATH is not set", file=sys.stderr)
        return 1

    payload = sys.stdin.read() if len(sys.argv) < 2 else sys.argv[1]
    try:
        request = json.loads(payload)
    except json.JSONDecodeError as error:
        print(f"invalid request json: {error}", file=sys.stderr)
        return 1

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(10)
            client.connect(path)
            client.sendall((json.dumps(request) + "\n").encode())
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
    print(line)
    return 0 if '"error"' not in line else 1


if __name__ == "__main__":
    sys.exit(main())
