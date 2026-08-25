"""
ingest_local.py — ingest the policy corpus from a local folder (no SFTP).

Same pipeline as ingest_policies.py (parse -> chunk -> embed -> upsert into
policy_chunk), but reads files straight from a directory baked into the image
(default ./policies). Use this on hosts where there's no SFTP sidecar — e.g.
Fly.io, Cloud Run, or any single-container deployment:

    python ingest_local.py                 # reads ./policies
    POLICIES_DIR=/data/policies python ingest_local.py

To refresh the corpus later without rebuilding the image, sync new files into
POLICIES_DIR (e.g. from a bucket) and re-run this script.
"""
import os

from dotenv import load_dotenv

from common import ingest_policy_document
from ingest_policies import industry_from_filename, domain_override_for

load_dotenv()

POLICIES_DIR = os.getenv("POLICIES_DIR", "policies")


def fetch_files(directory):
    """Read every file directly under `directory` into {name: bytes}."""
    files = {}
    for name in sorted(os.listdir(directory)):
        path = os.path.join(directory, name)
        if not os.path.isfile(path):
            continue
        with open(path, "rb") as fh:
            files[name] = fh.read()
    return files


def main():
    print(f"Reading policy corpus from ./{POLICIES_DIR} ...")
    files = fetch_files(POLICIES_DIR)
    print(f"Found {len(files)} file(s): {', '.join(files) or '(none)'}")

    total_chunks = 0

    for name, data in files.items():
        industry = industry_from_filename(name)
        domain_override = domain_override_for(name)
        try:
            result = ingest_policy_document(name, data, industry, domain_override)
        except ValueError as e:
            print(f"  ! skipping {name}: {e}")
            continue
        print(f"  {name}: industry={industry}, domain={result['domain']}, "
              f"version={result['version']}, {result['chunkCount']} chunk(s)")
        total_chunks += result["chunkCount"]

    print(f"Done. Upserted {total_chunks} chunk(s).")


if __name__ == "__main__":
    main()
