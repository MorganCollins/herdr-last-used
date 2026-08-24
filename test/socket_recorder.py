#!/usr/bin/env python3
"""Real unix socket server that records one request line, then replies ok.

Used instead of mocking socket_request.py, so the tests exercise the actual
framing the plugin sends to Herdr.
"""
import os
import socket
import sys

path, out = sys.argv[1], sys.argv[2]
if os.path.exists(path):
    os.unlink(path)

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(1)
server.settimeout(15)
print("ready", flush=True)

conn, _ = server.accept()
buffer = b""
while b"\n" not in buffer:
    chunk = conn.recv(65536)
    if not chunk:
        break
    buffer += chunk
with open(out, "wb") as handle:
    handle.write(buffer.split(b"\n", 1)[0])
conn.sendall(b'{"id":"x","result":{"type":"agent_view","active":true}}\n')
conn.close()
server.close()
os.unlink(path)
