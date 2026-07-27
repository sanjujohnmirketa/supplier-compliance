"""
migrate_existing_policies.py — ONE-TIME migration of the pre-existing local
policy corpus (policies/*.md) into Salesforce via the REAL upload path:

  for each file:
    1. sf api request rest -> insert Policy_Document__c (Status__c='Uploaded')
    2. sf api request rest -> insert ContentVersion (base64 file data) +
       ContentDocumentLink to that Policy_Document__c
    3. sf apex run         -> PolicyDocumentController.startIngestion(...)
       (same call the LWC's onuploadfinished handler makes)

This does NOT special-case the migration — it drives the identical Apex path
a Procurement Manager clicking "upload" in the new scPolicyUpload screen would
use, so it also serves as an end-to-end test of that new path.

Run from the supplierCompliance directory (needs an authenticated `sf` CLI
target org already set, e.g. --target-org supplierCompliance):

    python ../scripts/migrate_existing_policies.py --target-org supplierCompliance
"""
import argparse
import base64
import json
import subprocess
import sys
import tempfile
from pathlib import Path

POLICIES_DIR = Path(__file__).resolve().parent.parent / "policies"


def sf_api_rest(target_org, method, url, body=None):
    """Call `sf api request rest` and return the parsed JSON response."""
    cmd = ["sf", "api", "request", "rest", url, "-X", method,
           "--target-org", target_org, "--json"]
    body_file = None
    if body is not None:
        body_file = tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False, encoding="utf-8")
        json.dump(body, body_file)
        body_file.close()
        cmd += ["-b", body_file.name, "-H", "Content-Type:application/json"]

    result = subprocess.run(cmd, capture_output=True, text=True, shell=False)
    if body_file:
        Path(body_file.name).unlink(missing_ok=True)

    if result.returncode != 0:
        raise RuntimeError(f"sf api request rest failed: {result.stderr or result.stdout}")

    out = json.loads(result.stdout)
    return out.get("result", out)


def sf_apex_run(target_org, apex_body):
    """Run an anonymous Apex snippet via `sf apex run` (stdin)."""
    with tempfile.NamedTemporaryFile(
            mode="w", suffix=".apex", delete=False, encoding="utf-8") as f:
        f.write(apex_body)
        apex_file = f.name
    try:
        result = subprocess.run(
            ["sf", "apex", "run", "--file", apex_file, "--target-org", target_org, "--json"],
            capture_output=True, text=True, shell=False)
    finally:
        Path(apex_file).unlink(missing_ok=True)

    if result.returncode != 0:
        raise RuntimeError(f"sf apex run failed: {result.stderr or result.stdout}")
    return json.loads(result.stdout)


def create_policy_document(target_org):
    resp = sf_api_rest(target_org, "POST", "/services/data/v61.0/sobjects/Policy_Document__c",
                        body={"Status__c": "Uploaded", "Domain__c": "Auto-Detect"})
    return resp["id"]


def upload_content_version(target_org, policy_doc_id, file_path):
    data = file_path.read_bytes()
    b64 = base64.b64encode(data).decode("ascii")
    resp = sf_api_rest(target_org, "POST", "/services/data/v61.0/sobjects/ContentVersion",
                        body={
                            "Title": file_path.name,
                            "PathOnClient": file_path.name,
                            "VersionData": b64,
                        })
    cv_id = resp["id"]

    # Resolve ContentDocumentId from the ContentVersion we just inserted.
    cv = sf_api_rest(target_org, "GET",
                      f"/services/data/v61.0/sobjects/ContentVersion/{cv_id}"
                      "?fields=ContentDocumentId")
    content_document_id = cv["ContentDocumentId"]

    sf_api_rest(target_org, "POST", "/services/data/v61.0/sobjects/ContentDocumentLink",
                body={
                    "ContentDocumentId": content_document_id,
                    "LinkedEntityId": policy_doc_id,
                    "ShareType": "V",
                    "Visibility": "AllUsers",
                })
    return content_document_id


def start_ingestion(target_org, policy_doc_id, content_document_id):
    apex = f"""
PolicyDocumentController.startIngestion(
    '{policy_doc_id}', '{content_document_id}');
"""
    resp = sf_apex_run(target_org, apex)
    result = resp.get("result", {})
    if not result.get("compiled") or not result.get("success"):
        raise RuntimeError(
            "startIngestion Apex call failed: "
            f"compileProblem={result.get('compileProblem')!r} "
            f"exceptionMessage={result.get('exceptionMessage')!r}"
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target-org", required=True)
    args = parser.parse_args()

    files = sorted(POLICIES_DIR.glob("*.md"))
    if not files:
        print(f"No .md files found in {POLICIES_DIR}")
        sys.exit(1)

    print(f"Migrating {len(files)} existing policy file(s) from {POLICIES_DIR} "
          f"into org '{args.target_org}' via the real upload path...")

    failures = []
    for f in files:
        print(f"  {f.name} ...", end=" ", flush=True)
        try:
            policy_doc_id = create_policy_document(args.target_org)
            content_document_id = upload_content_version(args.target_org, policy_doc_id, f)
            start_ingestion(args.target_org, policy_doc_id, content_document_id)
            print(f"OK (Policy_Document__c={policy_doc_id})")
        except Exception as e:
            print(f"FAILED: {e}")
            failures.append((f.name, str(e)))

    print()
    if failures:
        print(f"Done with {len(failures)} failure(s):")
        for name, err in failures:
            print(f"  - {name}: {err}")
        sys.exit(1)
    print(f"Done. All {len(files)} file(s) submitted for ingestion — "
          f"check the Policy Documents tab in Salesforce for Status__c='Ingested'.")


if __name__ == "__main__":
    main()
