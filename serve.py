# Tiny development web server for Saap-Sidi.
#
# Same as Python's built-in one, except it tells the browser "never cache this".
# Without that, the browser happily keeps showing an old copy of the game after
# we change a file, which looks like a bug but isn't.

import http.server
import os

# Normally 5500. The tooling can hand us a different one via PORT when 5500 is
# already busy (for example when two chats are running a server at once).
PORT = int(os.environ.get("PORT") or 5500)
DIRECTORY = "frontend"


class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()


if __name__ == "__main__":
    # Threaded: the browser asks for several files at once, so we must be able to
    # answer more than one request at a time.
    http.server.ThreadingHTTPServer.allow_reuse_address = True
    with http.server.ThreadingHTTPServer(("", PORT), NoCacheHandler) as httpd:
        print(f"Saap-Sidi dev server on http://localhost:{PORT}")
        httpd.serve_forever()
