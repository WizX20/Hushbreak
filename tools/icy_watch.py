"""Print every change in the ICY metadata of a Shoutcast/Icecast stream, with wall-clock time."""
import sys
import time
import urllib.request

url = sys.argv[1]
req = urllib.request.Request(url, headers={"Icy-MetaData": "1", "User-Agent": "icy-watch/1"})
resp = urllib.request.urlopen(req, timeout=15)
metaint = int(resp.headers["icy-metaint"])
print(time.strftime("%H:%M:%S"), "connected, metaint", metaint, flush=True)

last = None
while True:
    audio = resp.read(metaint)
    if not audio:
        print(time.strftime("%H:%M:%S"), "stream ended", flush=True)
        break
    n = resp.read(1)[0] * 16
    meta = resp.read(n).rstrip(b"\x00").decode("utf-8", "replace") if n else ""
    if meta != last:
        print(time.strftime("%H:%M:%S"), "meta:", repr(meta), flush=True)
        last = meta
