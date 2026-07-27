"""
ingest_policies.py — pull policy files from SFTP, turn them into searchable rows.

Pipeline:  SFTP download -> parse to text -> chunk -> embed -> upsert into policy_chunk

Run it whenever the corpus changes:  python ingest_policies.py

Parsing/chunking/embedding/upsert logic lives in common.ingest_policy_document()
so this script and app.py's /policy/ingest (single-file HTTP upload from
Salesforce) stay identical — a policy uploaded via either path lands in
policy_chunk the same way.
"""
import os
import posixpath
from datetime import date

import paramiko
from dotenv import load_dotenv

from common import ingest_policy_document

load_dotenv()

SFTP_HOST = os.getenv("SFTP_HOST", "localhost")
SFTP_PORT = int(os.getenv("SFTP_PORT", "2222"))
SFTP_USER = os.getenv("SFTP_USER", "compliance")
SFTP_PASS = os.getenv("SFTP_PASS", "")
SFTP_DIR = os.getenv("SFTP_DIR", "/upload")


# ---------------------------------------------------------------------------
# Download every file from the SFTP folder into memory
# ---------------------------------------------------------------------------
def fetch_files():
    transport = paramiko.Transport((SFTP_HOST, SFTP_PORT))
    transport.connect(username=SFTP_USER, password=SFTP_PASS)
    sftp = paramiko.SFTPClient.from_transport(transport)

    files = {}
    for name in sftp.listdir(SFTP_DIR):
        remote_path = posixpath.join(SFTP_DIR, name)
        try:
            with sftp.open(remote_path, "rb") as fh:
                files[name] = fh.read()
        except IOError:
            # skip subdirectories or unreadable entries
            continue

    sftp.close()
    transport.close()
    return files


def main():
    print(f"Connecting to SFTP {SFTP_USER}@{SFTP_HOST}:{SFTP_PORT}{SFTP_DIR} ...")
    files = fetch_files()
    print(f"Found {len(files)} file(s): {', '.join(files) or '(none)'}")

    version = date.today().isoformat()  # use ingest date as the corpus version
    total_chunks = 0

    for name, data in files.items():
        try:
            result = ingest_policy_document(name, data, version)
        except ValueError as e:
            print(f"  ! skipping {name}: {e}")
            continue
        print(f"  {name}: domain={result['domain']}, {result['chunkCount']} chunk(s)")
        total_chunks += result["chunkCount"]

    print(f"Done. Upserted {total_chunks} chunk(s) at version {version}.")


if __name__ == "__main__":
    main()
