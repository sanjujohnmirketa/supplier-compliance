"""
ingest_policies.py — pull policy files from SFTP, turn them into searchable rows.

Pipeline:  SFTP download -> parse to text -> chunk -> embed -> upsert into policy_chunk

Run it whenever the corpus changes:  python ingest_policies.py
"""
import os
import io
import posixpath
from datetime import date

import paramiko
from dotenv import load_dotenv

from common import (
    get_conn, embed_texts, chunk_text, guess_domain,
    content_hash, to_pgvector,
)

load_dotenv()

SFTP_HOST = os.getenv("SFTP_HOST", "localhost")
SFTP_PORT = int(os.getenv("SFTP_PORT", "2222"))
SFTP_USER = os.getenv("SFTP_USER", "compliance")
SFTP_PASS = os.getenv("SFTP_PASS", "")
SFTP_DIR = os.getenv("SFTP_DIR", "/upload")


# ---------------------------------------------------------------------------
# 1. Download every file from the SFTP folder into memory
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


# ---------------------------------------------------------------------------
# 2. Turn raw bytes into plain text, based on file extension
# ---------------------------------------------------------------------------
def parse_file(name, data):
    ext = name.lower().rsplit(".", 1)[-1] if "." in name else ""

    if ext in ("txt", "md"):
        return data.decode("utf-8", errors="ignore")

    if ext == "pdf":
        import pdfplumber
        text_parts = []
        with pdfplumber.open(io.BytesIO(data)) as pdf:
            for page in pdf.pages:
                text_parts.append(page.extract_text() or "")
        return "\n\n".join(text_parts)

    if ext == "docx":
        import docx
        document = docx.Document(io.BytesIO(data))
        return "\n\n".join(p.text for p in document.paragraphs)

    print(f"  ! skipping unsupported file type: {name}")
    return ""


# ---------------------------------------------------------------------------
# 3. Upsert chunks (insert, or update if the same clause already exists)
# ---------------------------------------------------------------------------
UPSERT_SQL = """
INSERT INTO policy_chunk
    (source, version, clause_id, domain, chunk_index, text, content_hash, embedding)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s::vector)
ON CONFLICT (source, version, clause_id, chunk_index)
DO UPDATE SET
    text         = EXCLUDED.text,
    domain       = EXCLUDED.domain,
    content_hash = EXCLUDED.content_hash,
    embedding    = EXCLUDED.embedding;
"""


def main():
    print(f"Connecting to SFTP {SFTP_USER}@{SFTP_HOST}:{SFTP_PORT}{SFTP_DIR} ...")
    files = fetch_files()
    print(f"Found {len(files)} file(s): {', '.join(files) or '(none)'}")

    version = date.today().isoformat()  # use ingest date as the corpus version
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
                name,                      # source
                version,                   # version
                f"{name}#chunk{i}",        # clause_id (provenance)
                domain,                    # domain
                i,                         # chunk_index
                chunk,                     # text
                content_hash(chunk),       # content_hash
                to_pgvector(emb),          # embedding ('[...]'::vector)
            ))
            total_chunks += 1

    conn.commit()
    cur.close()
    conn.close()
    print(f"Done. Upserted {total_chunks} chunk(s) at version {version}.")


if __name__ == "__main__":
    main()
