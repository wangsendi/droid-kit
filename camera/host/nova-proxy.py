#!/usr/bin/env python3
"""TCP proxy: 127.0.0.1:8100 -> Nova (default 172.11.11.45:8100).

Nova's HTTP WebM preview checks that the request URL host is 127.0.0.1 /
localhost / ::1. Run this proxy on the Android host and point feed-nova.sh at
http://127.0.0.1:8100; the Host header stays 127.0.0.1 while the TCP stream is
forwarded to Nova. WebRTC signaling does not need this proxy.

Environment:
  NOVA_LISTEN    default 127.0.0.1:8100
  NOVA_UPSTREAM  default 172.11.11.45:8100
"""
import os
import socket
import threading


def parse_addr(value):
    host, _, port = value.rpartition(":")
    return host, int(port)


LISTEN = parse_addr(os.environ.get("NOVA_LISTEN", "127.0.0.1:8100"))
UPSTREAM = parse_addr(os.environ.get("NOVA_UPSTREAM", "172.11.11.45:8100"))


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            try:
                s.close()
            except Exception:
                pass


def handle(client):
    try:
        upstream = socket.create_connection(UPSTREAM, timeout=8)
    except Exception:
        client.close()
        return
    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()


def main():
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(LISTEN)
    server.listen(64)
    print(f"proxy {LISTEN[0]}:{LISTEN[1]} -> {UPSTREAM[0]}:{UPSTREAM[1]}", flush=True)
    while True:
        client, _ = server.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
