import socket
import sys
import threading
import time

STORAGE = {b"set", b"add", b"replace", b"append", b"prepend", b"cas"}


def server_to_client(server, client):
    try:
        while True:
            data = server.recv(65536)
            if not data:
                break
            client.sendall(data)
    except OSError:
        pass
    try:
        client.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def client_to_server(client, server):
    pending = b""
    line = b""
    skip = 0
    try:
        while True:
            data = client.recv(65536)
            if not data:
                break
            pending += data
            out = b""
            while pending:
                if skip:
                    n = min(skip, len(pending))
                    out += pending[:n]
                    pending = pending[n:]
                    skip -= n
                    continue
                nl = pending.find(b"\n")
                if nl < 0:
                    line += pending
                    out += pending
                    pending = b""
                    break
                piece = pending[:nl + 1]
                pending = pending[nl + 1:]
                whole = line + piece
                fresh = not line
                line = b""
                tokens = whole.split()
                if fresh and len(tokens) == 2 and tokens[0] == b"debugtime" and tokens[1].isdigit():
                    if out:
                        server.sendall(out)
                        out = b""
                    time.sleep(int(tokens[1]) + 0.05)
                    client.sendall(b"OK\r\n")
                    continue
                out += piece
                if len(tokens) >= 5 and tokens[0] in STORAGE and tokens[4].isdigit():
                    skip = int(tokens[4]) + 2
            if out:
                server.sendall(out)
    except OSError:
        pass
    try:
        server.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def handle(client, target):
    try:
        server = socket.create_connection(("127.0.0.1", target))
    except OSError:
        client.close()
        return
    for s in (client, server):
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    up = threading.Thread(target=client_to_server, args=(client, server), daemon=True)
    down = threading.Thread(target=server_to_client, args=(server, client), daemon=True)
    up.start()
    down.start()
    up.join()
    down.join()
    client.close()
    server.close()


def main():
    listen_port = int(sys.argv[1])
    target = int(sys.argv[2])
    ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(("127.0.0.1", listen_port))
    ls.listen(128)
    while True:
        client, _ = ls.accept()
        threading.Thread(target=handle, args=(client, target), daemon=True).start()


if __name__ == "__main__":
    main()
