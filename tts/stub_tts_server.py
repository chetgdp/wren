"""Test double for qwentts.cpp's tts-server (same CLI flags and routes).

Synthesized PCM is a constant sample whose value is derived from the
registered voice's transcript (voice_sample), so tests can tell from the
audio alone which voice spoke. GET /log returns every speech request.
"""

import argparse
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Half a second at 24 kHz: one segment per request keeps tests fast.
SAMPLES = 12000


def voice_sample(ref_text):
    return sum(ref_text.encode("utf-8")) % 20000 + 1


class StubHandler(BaseHTTPRequestHandler):
    voices = {}
    log = []

    def log_message(self, *args):
        pass

    def _reply(self, status, body=b"{}", content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        length = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(length) or b"{}")

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, b'{"ok": true}')
        elif self.path == "/log":
            self._reply(200, json.dumps(self.log).encode())
        else:
            self._reply(404)

    def do_POST(self):
        body = self._body()
        if self.path == "/v1/audio/voices":
            self.voices[body["name"]] = body["ref_text"]
            self._reply(200)
        elif self.path == "/v1/audio/speech":
            ref_text = self.voices.get(body["voice"])
            if ref_text is None:
                self._reply(404)
                return
            self.log.append({"voice": body["voice"], "ref_text": ref_text,
                             "input": body["input"]})
            pcm = voice_sample(ref_text).to_bytes(2, "little") * SAMPLES
            self._reply(200, pcm, "application/octet-stream")
        else:
            self._reply(404)

    def do_DELETE(self):
        name = self.path.rsplit("/", 1)[-1]
        self.voices.pop(name, None)
        self._reply(200)


def main():
    p = argparse.ArgumentParser()
    for flag in ("--model", "--codec", "--lang"):
        p.add_argument(flag)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    args = p.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), StubHandler)
    print(f"stub tts-server on {args.port}", file=sys.stderr)
    server.serve_forever()


if __name__ == "__main__":
    main()
