import socket


class Error(Exception):
    pass


class Client:
    def __init__(self, port, host="127.0.0.1"):
        self.sock = socket.create_connection((host, port))
        self.buf = b""

    def close(self):
        self.sock.close()

    def _fill(self):
        data = self.sock.recv(1 << 20)
        if not data:
            raise EOFError("connection closed")
        self.buf += data

    def _line(self):
        while True:
            i = self.buf.find(b"\r\n")
            if i >= 0:
                line = self.buf[:i]
                self.buf = self.buf[i + 2:]
                return line
            self._fill()

    def _read(self):
        line = self._line()
        kind, rest = line[:1], line[1:]
        if kind == b"+":
            return rest.decode("latin-1")
        if kind == b"-":
            return Error(rest.decode("latin-1"))
        if kind == b":":
            return int(rest)
        if kind == b"$":
            n = int(rest)
            if n < 0:
                return None
            while len(self.buf) < n + 2:
                self._fill()
            data = self.buf[:n]
            self.buf = self.buf[n + 2:]
            return data
        if kind == b"*":
            n = int(rest)
            if n < 0:
                return None
            return [self._read() for _ in range(n)]
        if kind in (b"~", b">"):
            n = int(rest)
            return [self._read() for _ in range(n)]
        if kind == b"%":
            n = int(rest)
            return [self._read() for _ in range(2 * n)]
        if kind == b"_":
            return None
        if kind == b",":
            return float(rest)
        if kind == b"#":
            return rest == b"t"
        if kind == b"(":
            return int(rest)
        if kind == b"=":
            n = int(rest)
            while len(self.buf) < n + 2:
                self._fill()
            data = self.buf[4:n]
            self.buf = self.buf[n + 2:]
            return data
        raise ValueError("unexpected reply %r" % line)

    @staticmethod
    def _encode(args):
        out = [b"*%d\r\n" % len(args)]
        for a in args:
            if isinstance(a, str):
                a = a.encode()
            elif isinstance(a, int):
                a = str(a).encode()
            elif isinstance(a, float):
                a = repr(a).encode()
            out.append(b"$%d\r\n%s\r\n" % (len(a), a))
        return b"".join(out)

    def call(self, *args):
        self.sock.sendall(self._encode(args))
        return self._read()

    def check(self, *args):
        r = self.call(*args)
        if isinstance(r, Error):
            raise r
        return r

    def pipeline(self, cmds):
        if not cmds:
            return []
        self.sock.sendall(b"".join(self._encode(c) for c in cmds))
        return [self._read() for _ in cmds]
