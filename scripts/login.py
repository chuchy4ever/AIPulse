#!/usr/bin/env python3
import subprocess
import json
import re
import sys
import os
import time
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
            ["claude", "auth", "status"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            return data.get("loggedIn", False)
    except Exception:
        pass
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

def notify(message):
    """Non-blocking: a dialog here would freeze the clipboard watch behind it."""
    subprocess.run(
        ["osascript", "-e",
         f'display notification "{message}" with title "Přihlášení do Claude Code"'],
        capture_output=True,
    )


# The code the browser hands out is base64url, optionally with the state after
# a hash. Loose enough to survive a format tweak, tight enough not to fire on
# whatever the user happened to copy earlier.
CODE_PATTERN = re.compile(r"^[A-Za-z0-9_\-]{16,}(#[A-Za-z0-9_\-]{6,})?$")


def wait_for_copied_code(timeout=180):
    """Claude Code has no loopback callback: the browser shows a code and waits
    for it to be pasted. Watching the clipboard turns that into one click on
    Kopírovat instead of a dialog the user has to fill in by hand."""
    def clipboard():
        try:
            return subprocess.run(["pbpaste"], capture_output=True, text=True, timeout=3).stdout.strip()
        except Exception:
            return ""

    before = clipboard()
    deadline = time.time() + timeout

    while time.time() < deadline:
        current = clipboard()
        if current and current != before and CODE_PATTERN.match(current):
            return current
        time.sleep(0.5)

    return None


def show_input_dialog(message, max_attempts=1):
    applescript = f'''
display dialog "{message}" ¬
    with title "Přihlášení do Claude Code" ¬
    default answer "" ¬
    buttons {{"Zrušit", "Přihlásit"}} ¬
    default button "Přihlásit" ¬
    cancel button "Zrušit"
'''
    result = subprocess.run(
        ["osascript", "-e", applescript],
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        return None

    text = result.stdout.strip()
    if text.startswith("button returned:Přihlásit, text returned:"):
        code = text.replace("button returned:Přihlásit, text returned:", "").strip()
        return code

    return None

def run_browser_login():
    """The whole sign-in in the browser. Returns True when it went through."""
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
        return False

    # The reason matters here: it decides whether the fallback is worth trying,
    # and a rate limit or a rejected redirect reads nothing alike.
    log_message(f"BROWSER_LOGIN_RC_{result.returncode}: {result.stderr.strip()[:200]}")
    return result.returncode == 0


def run_login():
    log_message("LOGIN_START")

    if check_logged_in():
        log_message("ALREADY_LOGGED_IN")
        show_dialog("Claude Code", "Už jsi přihlášený do Claude Code.")
        return True

    if run_browser_login() and check_logged_in():
        log_message("LOGIN_SUCCESS_BROWSER")
        show_dialog("Claude Code", "Přihlášení proběhlo úspěšně.")
        try:
            subprocess.Popen(["bash", str(COLLECT_SCRIPT)])
        except Exception as e:
            log_message(f"ERROR_STARTING_COLLECT: {e}")
        return True

    # Falling back to the CLI: it shows a code in the browser instead, which the
    # clipboard watch below picks up.
    log_message("STARTING_CLAUDE_AUTH_LOGIN")

    try:
        proc = subprocess.Popen(
            ["claude", "auth", "login"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
    except Exception as e:
        log_message(f"FAILED_TO_START_PROCESS: {e}")
        show_dialog("Chyba", "Nepodařilo se spustit přihlášení. Zkontroluj, jestli je Claude Code nainstalovaný.")
        return False

    attempt = 0
    max_attempts = 3
    browser_url = None

    while attempt < max_attempts:
        attempt += 1
        log_message(f"ATTEMPT_{attempt}")

        proc_output = []
        found_prompt = False

        try:
            while True:
                line = proc.stdout.readline()
                if not line:
                    break

                proc_output.append(line)

                if "Paste code here" in line:
                    found_prompt = True
                    break

                if "If the browser didn't open, visit:" in line:
                    browser_url = line.split("visit: ")[-1].strip()
                    log_message(f"BROWSER_URL_FOUND")
        except Exception as e:
            log_message(f"ERROR_READING_OUTPUT: {e}")
            pass

        if not found_prompt:
            log_message(f"NO_PROMPT_FOUND_ATTEMPT_{attempt}")
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
            show_dialog("Chyba", f"Přihlášení nereaguje. Zkus to později.")
            log_message("LOGIN_FAILED_NO_PROMPT")
            return False

        notify("Přihlas se v prohlížeči a klikni na kopírování kódu. Zbytek dodělám sám.")
        code = wait_for_copied_code()

        if code is not None:
            log_message(f"CODE_FROM_CLIPBOARD_ATTEMPT_{attempt}")
        else:
            # The watch can miss it - a code typed by hand, a clipboard manager
            # in the way - so the old dialog stays as the way out.
            log_message(f"CLIPBOARD_TIMEOUT_ATTEMPT_{attempt}")
            code = show_input_dialog("Kód se nepodařilo přečíst ze schránky. Vlož ho sem.")

        if code is None:
            log_message(f"USER_CANCELLED_ATTEMPT_{attempt}")
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
            log_message("LOGIN_CANCELLED")
            return False

        try:
            proc.stdin.write(code + "\n")
            proc.stdin.flush()
            log_message(f"CODE_SENT_ATTEMPT_{attempt}")
        except Exception as e:
            log_message(f"ERROR_SENDING_CODE: {e}")
            if proc.poll() is None:
                proc.terminate()
            show_dialog("Chyba", "Nepodařilo se odeslat kód.")
            log_message("LOGIN_FAILED_SEND_ERROR")
            return False

        try:
            _, _ = proc.communicate(timeout=60)
            log_message(f"PROCESS_COMPLETED_ATTEMPT_{attempt}")
        except subprocess.TimeoutExpired:
            log_message(f"PROCESS_TIMEOUT_ATTEMPT_{attempt}")
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
            show_dialog("Chyba", "Přihlášení trvalo moc dlouho. Zkus to později.")
            log_message("LOGIN_FAILED_TIMEOUT")
            return False

        if check_logged_in():
            log_message("LOGIN_SUCCESS")
            show_dialog("Claude Code", "Přihlášení proběhlo úspěšně.")

            try:
                subprocess.Popen(["bash", str(COLLECT_SCRIPT)])
                log_message("COLLECT_SCRIPT_STARTED")
            except Exception as e:
                log_message(f"ERROR_STARTING_COLLECT: {e}")

            return True

        log_message(f"INVALID_CODE_ATTEMPT_{attempt}")

        if attempt < max_attempts:
            proc = subprocess.Popen(
                ["claude", "auth", "login"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )

    log_message("MAX_ATTEMPTS_EXCEEDED")
    show_dialog("Chyba", "Převýšil jsi maximální počet pokusů. Zkus to později.")
    return False

if __name__ == "__main__":
    set_path()
    success = run_login()
    sys.exit(0 if success else 1)
