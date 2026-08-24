#!/usr/bin/env python3
"""Real unix socket server that records one request line, then replies.

Used instead of mocking socket_request.py, so the tests exercise the actual
framing the plugin sends to Herdr.

usage: socket_recorder.py <socket-path> <out-file> [response-json]
"""
import os
import socket
import sys

path, out = sys.argv[1], sys.argv[2]
response = sys.argv[3] if len(sys.argv) > 3 else '{"id":"x","result":{"type":"agent_view","active":true}}'

if os.path.exists(path):
    os.unlink(path)

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(1)
server.settimeout(15)
print("ready", flush=True)

try:
    conn, _ = server.accept()
except socket.timeout:
    # No client arrived. Tests that assert "nothing was sent" rely on this
    # exiting quietly rather than hanging or erroring.
    server.close()
    os.unlink(path)
    sys.exit(0)

# The accepted connection does not inherit the listener's timeout; without this
# a client that connects and never sends a newline blocks forever.
conn.settimeout(15)
buffer = b""
try:
    while b"\n" not in buffer:
        chunk = conn.recv(65536)
        if not chunk:
            break
        buffer += chunk
except socket.timeout:
    pass

if buffer:
    with open(out, "wb") as handle:
        handle.write(buffer.split(b"\n", 1)[0])

conn.sendall(response.encode() + b"\n")
conn.close()
server.close()
os.unlink(path)
