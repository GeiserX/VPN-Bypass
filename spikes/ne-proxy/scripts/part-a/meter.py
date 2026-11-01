# reads a byte stream on stdin, prints once a second: local time, bytes that second, total
import sys, threading, time
total = 0; lock = threading.Lock(); done = False
def rd():
    global total, done
    f = sys.stdin.buffer
    while True:
        b = f.read1(65536)
        if not b: break
        with lock: total += len(b)
    done = True
threading.Thread(target=rd, daemon=True).start()
last = 0
while True:
    time.sleep(1)
    with lock: t = total
    print(time.strftime('%H:%M:%S'), t - last, t, flush=True); last = t
    if done:
        print(time.strftime('%H:%M:%S'), 'EOF', t, flush=True); break
