"""
eval_harness.py — continuous-evaluation regression harness (Pillar 3).

Runs the golden set (eval/golden.jsonl) through the live /assess endpoint and
checks each case's assertions: verdict, deterministic gates (expiry/coverage),
extracted fields, and registry status. Run after every prompt (skills.md) or code
change to catch regressions before they ship.

    python eval_harness.py            # uses http://127.0.0.1:8000
    python eval_harness.py --url ...  # custom engine URL

Exit code is non-zero if any assertion fails (CI-friendly).
"""
import json
import os
import sys
import requests

URL = "http://127.0.0.1:8000"
for i, a in enumerate(sys.argv):
    if a == "--url" and i + 1 < len(sys.argv):
        URL = sys.argv[i + 1]

_ROOT = os.path.dirname(__file__)
TOKEN = next((l.split("=", 1)[1].strip() for l in open(os.path.join(_ROOT, ".env"))
              if l.startswith("INBOUND_TOKEN")), "")
HEADERS = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}


def _assert(case_id, name, ok, detail=""):
    mark = "PASS" if ok else "FAIL"
    print(f"  [{mark}] {name}" + (f" — {detail}" if detail else ""))
    return ok


def run():
    cases = [json.loads(l) for l in open(os.path.join(_ROOT, "eval", "golden.jsonl")) if l.strip()]
    total = passed = 0
    for c in cases:
        print(f"\n• {c['id']}")
        r = requests.post(f"{URL}/assess", headers=HEADERS, json={
            "supplierId": "EVAL", "documentType": c.get("documentType"),
            "documentText": c.get("documentText")}, timeout=120)
        d = r.json()
        fields = d.get("extractedFields") or {}
        kd = d.get("keyDates") or {}
        rv = d.get("registryValidation") or {}
        exp = c.get("expect", {})

        for key, want in exp.items():
            total += 1
            if key == "verdict":
                ok = _assert(c["id"], "verdict", d.get("verdict") == want, f"{d.get('verdict')} (want {want})")
            elif key == "verdict_in":
                ok = _assert(c["id"], "verdict_in", d.get("verdict") in want, f"{d.get('verdict')}")
            elif key == "is_expired":
                ok = _assert(c["id"], "is_expired", kd.get("is_expired") == want, f"{kd.get('is_expired')}")
            elif key == "coverage_amount":
                got = fields.get("coverage_amount")
                ok = _assert(c["id"], "coverage_amount", _num(got) == want, f"{got}")
            elif key == "gates_pass":
                checks = d.get("clauseChecks") or []
                det = [x for x in checks if x.get("requirement", "").startswith(("Document expiration", "Coverage"))]
                ok = _assert(c["id"], "deterministic gates pass", all(x.get("pass") for x in det), f"{len(det)} gates")
            elif key == "registry_status":
                ok = _assert(c["id"], "registry status", rv.get("status") == want, f"{rv.get('status')}")
            else:
                ok = _assert(c["id"], key, False, "unknown assertion")
            passed += 1 if ok else 0

    print(f"\n{'='*48}\nSCORE: {passed}/{total} assertions passed "
          f"({100*passed//max(total,1)}%)")
    return 0 if passed == total else 1


def _num(v):
    try:
        return float(str(v).replace(",", "").replace("$", ""))
    except (TypeError, ValueError):
        return None


if __name__ == "__main__":
    sys.exit(run())
