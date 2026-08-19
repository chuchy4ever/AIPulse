import json, sys, os, datetime, tempfile

payload_path, data_path = sys.argv[1], sys.argv[2]

# The app shows this script's stderr to the user, so a traceback would end up
# on screen as the explanation of what went wrong.
try:
    with open(payload_path) as handle:
        payload = json.load(handle)
except (OSError, json.JSONDecodeError):
    print(f"usage payload is missing or not valid JSON: {payload_path}", file=sys.stderr)
    sys.exit(1)

try:
    with open(data_path) as handle:
        data = json.load(handle)
except FileNotFoundError:
    print(f"data file not found: {data_path}", file=sys.stderr)
    sys.exit(1)
except json.JSONDecodeError:
    print(f"data file is not valid JSON: {data_path}", file=sys.stderr)
    sys.exit(1)

previous = data.get("limits") or {}

# A missing section must not land in data.json as null: the app decodes limits
# into non-optional fields, so one null takes the whole file down with it.
def section(node, fallback):
    if not node:
        return fallback
    return {"percent": int(round(node.get("utilization") or 0)),
            "resetsAt": node.get("resets_at")}

session = section(payload.get("five_hour"), previous.get("session"))
weekly = section(payload.get("seven_day"), previous.get("weekly"))

if session is None or weekly is None:
    print("usage payload carried no five_hour/seven_day section", file=sys.stderr)
    sys.exit(1)

data["limits"] = {
    "session": session,
    "weekly": weekly,
    "fetchedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
# Not data_path + ".tmp": collect.sh streams its own output into exactly that
# name, and truncating it mid-write leaves the collector's remaining bytes
# landing straight in data.json.
handle = tempfile.NamedTemporaryFile("w", dir=os.path.dirname(data_path),
                                     prefix=".limits.", suffix=".tmp", delete=False)
try:
    json.dump(data, handle)
    handle.close()
    os.replace(handle.name, data_path)
except BaseException:
    handle.close()
    os.unlink(handle.name)
    raise
print(f"session {data['limits']['session']['percent']} %, weekly {data['limits']['weekly']['percent']} %")
