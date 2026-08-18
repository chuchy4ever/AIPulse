import json, sys, os, datetime

payload_path, data_path = sys.argv[1], sys.argv[2]
with open(payload_path) as handle:
    payload = json.load(handle)

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
tmp = data_path + ".tmp"
with open(tmp, "w") as handle:
    json.dump(data, handle)
os.replace(tmp, data_path)
print(f"session {data['limits']['session']['percent']} %, weekly {data['limits']['weekly']['percent']} %")
