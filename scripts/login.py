#!/usr/bin/env python3
import subprocess
import sys
import os
from pathlib import Path
from datetime import datetime

LOG_PATH = Path.home() / ".local/share/aipulse/login.log"
COLLECT_SCRIPT = Path.home() / ".local/share/aipulse/collect.sh"

def log_message(msg):
    timestamp = datetime.now().isoformat()
    with open(LOG_PATH, "a") as f:
        f.write(f"{timestamp} | {msg}\n")

def set_path():
    path_dirs = [
        os.path.expanduser("~/.local/bin"),
        "/opt/homebrew/bin",
        "/usr/bin",
        "/bin",
    ]
    existing = os.environ.get("PATH", "")
    os.environ["PATH"] = ":".join(path_dirs + ([existing] if existing else []))

def check_logged_in():
    try:
        result = subprocess.run(
            ["bash", str(Path.home() / ".local/share/aipulse/ensure-token.sh")],
            capture_output=True,
            text=True,
            timeout=30,
        )
        return result.returncode == 0
    except Exception:
        return False

def show_dialog(title, message, ok_button="OK", cancel_button=None):
    applescript = f'display dialog "{message}" with title "{title}" default button "{ok_button}"'
    if cancel_button:
        applescript = f'display dialog "{message}" with title "{title}" buttons {{"{cancel_button}", "{ok_button}"}} default button "{ok_button}"'

    result = subprocess.run(
        ["osascript", "-e", applescript],
        capture_output=True,
        text=True,
    )
    return result.returncode == 0

# Return codes of oauth-login.py, in the only grouping that matters here:
# whether reopening the browser with the older flow could still help.
BROWSER_OK = 0
BROWSER_USER_STOPPED = (2, 3, 4)   # timed out, refused, mismatched state


def refresh_now():
    """Runs the collector so data.json stops describing a state that is over."""
    try:
        subprocess.run(["bash", str(COLLECT_SCRIPT)], timeout=120,
                       capture_output=True)
    except Exception as e:
        log_message(f"ERROR_REFRESHING: {type(e).__name__}")


def run_browser_login():
    """The whole sign-in in the browser. Returns the script's exit code."""
    script = Path(__file__).with_name("oauth-login.py")
    if not script.exists():
        script = Path.home() / ".local/share/aipulse/oauth-login.py"

    try:
        result = subprocess.run(
            [sys.executable, str(script)],
            capture_output=True, text=True, timeout=360,
        )
    except Exception as e:
        log_message(f"BROWSER_LOGIN_ERROR: {type(e).__name__}")
        return 1

    # The reason matters here: it decides whether the fallback is worth trying,
    # and a rate limit or a rejected redirect reads nothing alike.
    log_message(f"BROWSER_LOGIN_RC_{result.returncode}: {result.stderr.strip()[:200]}")
    return result.returncode


def run_login():
    log_message("LOGIN_START")

    if check_logged_in():
        log_message("ALREADY_LOGGED_IN")
        # The panel shows the last collection, so after a sign-in that happened
        # elsewhere it keeps saying "Nepřihlášen" for up to five minutes - which
        # is exactly when the user clicks this button and is told he is already
        # signed in. Collect now so the answer and the panel agree.
        refresh_now()
        show_dialog("Claude Code", "Už jsi přihlášený do Claude Code, stav se právě obnovil.")
        return True

    browser_rc = run_browser_login()

    if browser_rc == BROWSER_OK:
        log_message("LOGIN_SUCCESS_BROWSER")
        show_dialog("Claude Code", "Přihlášení proběhlo úspěšně.")
        # Synchronous on purpose: the success dialog should not appear over a
        # panel that still says the opposite.
        refresh_now()
        return True

    # Walking away or refusing is an answer. Opening a second window with the
    # older flow would read as the app ignoring it.
    if browser_rc in BROWSER_USER_STOPPED:
        log_message(f"LOGIN_ABORTED_BY_USER_RC_{browser_rc}")
        show_dialog("Claude Code", "Přihlášení nedoběhlo. Zkus to znovu z nastavení.")
        return False

    log_message(f"LOGIN_FAILED_RC_{browser_rc}")
    show_dialog("Claude Code", "Přihlášení se nepodařilo. Zkus to znovu z nastavení.")
    return False

if __name__ == "__main__":
    set_path()
    success = run_login()
    sys.exit(0 if success else 1)
