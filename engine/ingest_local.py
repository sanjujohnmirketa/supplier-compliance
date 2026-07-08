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
from datetime import date

from dotenv import load_dotenv

from common import (
    get_conn, embed_texts, chunk_text, guess_domain,
    content_hash, to_pgvector,
)
# Reuse the exact same parser + upsert SQL the SFTP ingester uses.
from ingest_policies import parse_file, UPSERT_SQL

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

    version = date.today().isoformat()  # ingest date is the corpus version
    conn = get_conn()
    cur = conn.cursor()
    total_chunks = 0

    for name, data in files.items():
        text = parse_file(name, data)
        if not text.strip():
            continue

        chunks = chunk_text(text)
        domain = guess_domain(text)
        embeddings = embed_texts(chunks)
        print(f"  {name}: domain={domain}, {len(chunks)} chunk(s)")

        for i, (chunk, emb) in enumerate(zip(chunks, embeddings)):
            cur.execute(UPSERT_SQL, (
                name,
                version,
                f"{name}#chunk{i}",
                domain,
                i,
                chunk,
                content_hash(chunk),
                to_pgvector(emb),
            ))
            total_chunks += 1

    conn.commit()
    cur.close()
    conn.close()
    print(f"Done. Upserted {total_chunks} chunk(s) at version {version}.")


if __name__ == "__main__":
    main()
