import socket
import sys
import time

port = int(sys.argv[1])
duration = float(sys.argv[2])
window_from = float(sys.argv[3]) if len(sys.argv) > 3 else -1.0
window_to = float(sys.argv[4]) if len(sys.argv) > 4 else -1.0
s = socket.create_connection(("127.0.0.1", port))
s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
start = time.perf_counter()
count = 0
worst_in = (0.0, 0.0)
worst_out = (0.0, 0.0)
while True:
    now = time.perf_counter()
    at = now - start
    if at >= duration:
        break
    s.sendall(b"PING\r\n")
    buf = b""
    while not buf.endswith(b"\r\n"):
        buf += s.recv(64)
    rtt = time.perf_counter() - now
    count += 1
    if window_from <= at <= window_to:
        if rtt > worst_in[0]:
            worst_in = (rtt, at)
    elif at >= 1.0 and rtt > worst_out[0]:
        worst_out = (rtt, at)
line = "probe: %d pings, max rtt outside the save window %.3f ms at %.2f s" % (count, worst_out[0] * 1000, worst_out[1])
if window_from >= 0:
    line += ", inside %.1f..%.1f s %.3f ms at %.2f s" % (window_from, window_to, worst_in[0] * 1000, worst_in[1])
print(line)
