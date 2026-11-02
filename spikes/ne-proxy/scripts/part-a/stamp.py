# prefixes each stdin line with the local receive time
import sys, time
for line in sys.stdin:
    print(time.strftime('%H:%M:%S'), line.rstrip(), flush=True)
print(time.strftime('%H:%M:%S'), 'EOF', flush=True)
