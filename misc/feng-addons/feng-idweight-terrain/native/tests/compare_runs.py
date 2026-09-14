"""Compare two run_all.py JSON results, test by test."""
import json
import sys

before = {r["name"]: r for r in json.load(open(sys.argv[1], encoding="utf-8"))}
after = {r["name"]: r for r in json.load(open(sys.argv[2], encoding="utf-8"))}
changed = 0
for name, row in before.items():
    now = after.get(name, {"status": "missing"})
    flag = ""
    if row["status"] != now["status"]:
        flag = "   <== CHANGED"
        changed += 1
    print(f"{name:24} {row['status']:8} -> {now['status']:8}{flag}")
    if flag:
        print(f"    before: {'; '.join(row['lines']) or '(no markers)'}")
        print(f"    after : {'; '.join(now.get('lines', [])) or '(no markers)'}")
print(f"\n{len(before) - changed}/{len(before)} unchanged")
