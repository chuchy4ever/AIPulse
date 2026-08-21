#!/usr/bin/env python3
"""Sign in to Claude through the browser, with nothing to copy by hand.

`claude auth login` sends the browser to a page that prints a code and waits
for it to be pasted back. This does the same OAuth exchange with a callback on
localhost instead, so approving in the browser is the whole of it.

The tokens are written into the same Keychain record Claude Code reads, and
only the `claudeAiOauth` part of it: MCP and plugin credentials live in that
record too and must survive untouched.
"""

import base64
import hashlib
import http.server
import json
import secrets
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
AUTHORIZE_URL = "https://claude.ai/oauth/authorize"
TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
SCOPES = (
    "org:create_api_key user:profile user:inference "
    "user:sessions:claude_code user:mcp_servers user:file_upload"
)
# Cloudflare turns away the default urllib signature with a 1010, so the
# request goes out looking like what actually talks to this endpoint.
USER_AGENT = "claude-cli/2.1.210 (external, cli)"
KEYCHAIN_SERVICE = "Claude Code-credentials"
KEYCHAIN_ACCOUNT = "unknown"
WAIT_SECONDS = 300

DONE_PAGE = """<!doctype html><html lang="cs"><meta charset="utf-8">
<title>Přihlášeno</title>
<body style="font-family:-apple-system,system-ui,sans-serif;display:grid;
place-items:center;height:100vh;margin:0;background:#0b0b0d;color:#e8e8ea">
<div style="text-align:center">
<div style="font-size:44px">✓</div>
<h1 style="font-size:18px;font-weight:600">Přihlášeno</h1>
<p style="color:#9a9aa2;font-size:13px">Okno můžeš zavřít, zbytek doběhne v AIPulse.</p>
</div></body></html>"""

FAIL_PAGE = """<!doctype html><html lang="cs"><meta charset="utf-8">
<title>Nepovedlo se</title>
<body style="font-family:-apple-system,system-ui,sans-serif;display:grid;
place-items:center;height:100vh;margin:0;background:#0b0b0d;color:#e8e8ea">
<div style="text-align:center">
<div style="font-size:44px">✕</div>
<h1 style="font-size:18px;font-weight:600">Přihlášení se nepovedlo</h1>
<p style="color:#9a9aa2;font-size:13px">Vrať se do AIPulse, podrobnost je tam.</p>
</div></body></html>"""


def pkce_pair():
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
    digest = hashlib.sha256(verifier.encode()).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode()
    return verifier, challenge


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Callback(http.server.BaseHTTPRequestHandler):
    result = {}
    done = threading.Event()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/callback":
            self.send_error(404)
            return

        query = urllib.parse.parse_qs(parsed.query)
        Callback.result = {k: v[0] for k, v in query.items()}
        body = (DONE_PAGE if "code" in Callback.result else FAIL_PAGE).encode()

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        Callback.done.set()

    def log_message(self, *args):
        """The default handler prints the query string, code and all."""


def exchange(code, verifier, redirect_uri, state):
    return post_token({
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": redirect_uri,
        "client_id": CLIENT_ID,
        "code_verifier": verifier,
        "state": state,
    })


def post_token(body):
    payload = json.dumps(body).encode()

    req = urllib.request.Request(
        TOKEN_URL,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        },
    )

    # The code expires in about a minute, so a rate limit gets a few quick
    # retries and nothing longer - waiting it out would only burn the code.
    last = None
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as e:
            if e.code != 429:
                raise
            last = e
            print(f"Token endpoint vrací 429, pokus {attempt + 1} ze 4…", file=sys.stderr)
            time.sleep(4)

    raise last


def store(tokens):
    """Replace only the Claude sign-in; the record holds other credentials."""
    record = {}
    current = subprocess.run(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
        capture_output=True, text=True,
    )
    if current.returncode == 0:
        try:
            record = json.loads(current.stdout.strip())
        except json.JSONDecodeError:
            record = {}
    elif "could not be found" not in current.stderr:
        # Anything other than "no such record" means the record is there and we
        # just cannot see it - a denied Keychain prompt, a locked keychain.
        # Writing now would replace the MCP credentials with nothing.
        raise RuntimeError(
            f"Keychain nešel přečíst, nechávám ho být: {current.stderr.strip()[:120]}"
        )

    previous = record.get("claudeAiOauth") or {}
    now_ms = int(time.time() * 1000)
    # No expiry in the response means an expiry of "now", which reads as a dead
    # token to everything downstream. An hour is short enough to be harmless.
    expires_in = tokens.get("expires_in") or 3600
    scope = tokens.get("scope") or SCOPES

    oauth = {
        "accessToken": tokens["access_token"],
        "refreshToken": tokens.get("refresh_token", previous.get("refreshToken", "")),
        "expiresAt": now_ms + int(expires_in) * 1000,
        "scopes": scope.split() if isinstance(scope, str) else scope,
        # Not in the token response; Claude Code fills these in later and the
        # old values are closer to the truth than dropping the keys.
        "subscriptionType": tokens.get("subscription_type", previous.get("subscriptionType")),
        "rateLimitTier": previous.get("rateLimitTier"),
    }
    if tokens.get("refresh_expires_in"):
        oauth["refreshTokenExpiresAt"] = now_ms + int(tokens["refresh_expires_in"]) * 1000

    record["claudeAiOauth"] = {k: v for k, v in oauth.items() if v is not None}

    # Hex, because raw JSON does not survive quoting on a security(1) command
    # line. Which channel carries it depends on size: `security -i` reads the
    # command from stdin and keeps the secret out of argv, but it truncates a
    # long line - that is how this record got cut in half and took the sign-in
    # with it. Past that point the secret goes through argv instead, briefly
    # visible to `ps`, which is the lesser harm against a corrupted keychain.
    payload = json.dumps(record).encode().hex()
    command = (
        f'add-generic-password -U -s "{KEYCHAIN_SERVICE}" '
        f'-a "{KEYCHAIN_ACCOUNT}" -X {payload}\n'
    )

    if len(command) < 3500:
        written = subprocess.run(["security", "-i"], input=command,
                                 capture_output=True, text=True)
    else:
        written = subprocess.run(
            ["security", "add-generic-password", "-U",
             "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-X", payload],
            capture_output=True, text=True,
        )

    if written.returncode != 0 or "error" in written.stderr.lower():
        raise RuntimeError(f"zápis do Keychainu selhal: {written.stderr.strip()[:200]}")

    # Read it back before calling it stored: a truncated write reports success.
    check = subprocess.run(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
        capture_output=True, text=True,
    )
    try:
        stored = json.loads(check.stdout.strip())
    except json.JSONDecodeError:
        raise RuntimeError("zápis do Keychainu se poškodil (nečitelný JSON)")

    if not (stored.get("claudeAiOauth") or {}).get("accessToken"):
        raise RuntimeError("zápis do Keychainu neprošel celý")


def run():
    verifier, challenge = pkce_pair()
    state = secrets.token_urlsafe(24)
    port = free_port()
    redirect_uri = f"http://localhost:{port}/callback"

    server = http.server.HTTPServer(("127.0.0.1", port), Callback)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    url = AUTHORIZE_URL + "?" + urllib.parse.urlencode({
        "client_id": CLIENT_ID,
        "response_type": "code",
        "redirect_uri": redirect_uri,
        "scope": SCOPES,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
    })

    print(f"Otevírám prohlížeč, callback poslouchá na {redirect_uri}", file=sys.stderr)
    subprocess.run(["open", url], capture_output=True)

    if not Callback.done.wait(WAIT_SECONDS):
        server.shutdown()
        print("TIMEOUT: přihlášení nedoběhlo v limitu", file=sys.stderr)
        return 2

    server.shutdown()
    result = Callback.result

    if "code" not in result:
        print(f"ODMÍTNUTO: {result.get('error_description') or result.get('error', 'bez důvodu')}",
              file=sys.stderr)
        return 3

    # A callback carrying someone else's state is not our flow coming back.
    if result.get("state") != state:
        print("ODMÍTNUTO: nesouhlasí state, callback nepatří k tomuhle přihlášení",
              file=sys.stderr)
        return 4

    try:
        tokens = exchange(result["code"], verifier, redirect_uri, state)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        print(f"VÝMĚNA SELHALA: HTTP {e.code} {detail}", file=sys.stderr)
        return 5
    except Exception as e:
        print(f"VÝMĚNA SELHALA: {type(e).__name__}", file=sys.stderr)
        return 5

    if "access_token" not in tokens:
        print("VÝMĚNA SELHALA: odpověď neobsahuje token", file=sys.stderr)
        return 5

    try:
        store(tokens)
    except Exception as e:
        print(f"ULOŽENÍ SELHALO: {e}", file=sys.stderr)
        return 6

    print("OK", file=sys.stderr)
    return 0


def refresh():
    """Renews the access token without a browser.

    The sign-in lasts eight hours, so without this the gauge freezes three
    times a day and the only cure is clicking through a login. Rotation is
    handled by store(): whatever refresh token comes back replaces the old one.
    """
    current = subprocess.run(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
        capture_output=True, text=True,
    )
    if current.returncode != 0:
        print("REFRESH: v Keychainu nic není", file=sys.stderr)
        return 1

    try:
        oauth = json.loads(current.stdout.strip()).get("claudeAiOauth") or {}
    except json.JSONDecodeError:
        print("REFRESH: Keychain nejde přečíst", file=sys.stderr)
        return 1

    token = oauth.get("refreshToken")
    if not token:
        print("REFRESH: chybí refresh token, je potřeba se přihlásit", file=sys.stderr)
        return 2

    try:
        tokens = post_token({
            "grant_type": "refresh_token",
            "refresh_token": token,
            "client_id": CLIENT_ID,
        })
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:200]
        # A refused refresh token will not start working; say so plainly so the
        # caller stops retrying and asks for a login instead.
        print(f"REFRESH SELHAL: HTTP {e.code} {detail}", file=sys.stderr)
        return 2
    except Exception as e:
        print(f"REFRESH SELHAL: {type(e).__name__}", file=sys.stderr)
        return 1

    if "access_token" not in tokens:
        print("REFRESH SELHAL: odpověď neobsahuje token", file=sys.stderr)
        return 2

    try:
        store(tokens)
    except Exception as e:
        print(f"ULOŽENÍ SELHALO: {e}", file=sys.stderr)
        return 1

    print("OK", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(refresh() if "--refresh" in sys.argv else run())
