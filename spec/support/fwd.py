# TCP forwarder standing in for `aws ssm start-session` with
# AWS-StartPortForwardingSession: listens on localPortNumber, forwards the
# first connection to portNumber on 127.0.0.1.  Like the plugin it then stays
# up until it is killed.
import json, socket, sys, threading, time

p = json.loads(sys.argv[1])
local_port = int(p["localPortNumber"][0])
remote_port = int(p["portNumber"][0])
time.sleep(0.2)
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", local_port))
s.listen(1)
c, _ = s.accept()
r = socket.create_connection(("127.0.0.1", remote_port))


def pump(a, b):
    while True:
        try:
            d = a.recv(65536)
        except OSError:
            d = b""
        if not d:
            try:
                b.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            return
        try:
            b.sendall(d)
        except OSError:
            return


t1 = threading.Thread(target=pump, args=(c, r))
t2 = threading.Thread(target=pump, args=(r, c))
t1.start()
t2.start()
t1.join()
t2.join()
time.sleep(3600)
