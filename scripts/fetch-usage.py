import json
import sys
import urllib.error
import urllib.request

ENDPOINT = "https://api.anthropic.com/api/oauth/usage"

def main() -> int:
    token = sys.stdin.read().strip()
    if not token:
        print("no token on stdin", file=sys.stderr)
        return 1

    request = urllib.request.Request(ENDPOINT)
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("anthropic-beta", "oauth-2025-04-20")

    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            payload = response.read()
    except urllib.error.HTTPError as error:
        print(f"HTTP {error.code}", file=sys.stderr)
        return 1
    except Exception as error:
        print(f"{type(error).__name__}", file=sys.stderr)
        return 1

    # A non-JSON body means the endpoint changed or an error page came back;
    # writing it out would only corrupt data.json further down the line.
    try:
        json.loads(payload)
    except ValueError:
        print("response was not JSON", file=sys.stderr)
        return 1

    with open(sys.argv[1], "wb") as handle:
        handle.write(payload)
    return 0

sys.exit(main())
