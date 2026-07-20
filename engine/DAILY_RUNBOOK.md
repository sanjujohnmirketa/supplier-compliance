# Daily Runbook — supplier-compliance-local

Everything you need to run **each time you sit down to work**, plus the workflow
for adding new policies. Beginner-friendly; run commands from the project folder
`C:\Users\johns\supplier-compliance-local` in **PowerShell**.

---

## A. What persists between sessions (so you DON'T redo it)

| Thing | Persists? | Meaning |
|-------|-----------|---------|
| Ingested policy chunks (the DB) | ✅ Yes — stored in the `pgdata` Docker volume | You do **not** re-ingest every session. Only when policies change. |
| The embedding model | ✅ Yes — cached on disk after first download | Fast after the first ever run. |
| `.venv` (Python deps) | ✅ Yes | Created once. You only **activate** it each session, never recreate. |
| Running containers | ❌ No (stop when Docker/PC shuts down) | You start them each session with one command. |
| The `uvicorn` service | ❌ No | You start it each session. |

> ⚠️ **Never run `docker compose down -v`** in normal use — the `-v` deletes the
> `pgdata` volume and wipes all ingested policies. Use `docker compose stop` instead.

---

## B. START OF SESSION — get the service running (≈1 min)

**1. Open Docker Desktop** and wait until it says *"Engine running"* (whale icon
steady in the system tray). Docker must be running before any `docker` command works.

**2. Start the containers** (Postgres + SFTP):
```powershell
cd C:\Users\johns\supplier-compliance-local
docker compose up -d
```
If they're already running, this just confirms it — safe to run anytime.

**3. Verify both are up:**
```powershell
docker ps --format "{{.Names}}`t{{.Status}}"
```
Expect `compliance-db` and `compliance-sftp`, both `Up`.

**4. Activate the Python environment** (prompt should change to `(.venv)`):
```powershell
.venv\Scripts\activate
```

**5. Start the API service:**
```powershell
uvicorn app:app --reload --port 8000
```
Leave this terminal running. It serves `/scope`, `/extract`, `/health`.

**6. (Optional) Quick health check** — in a **second** terminal:
```powershell
Invoke-RestMethod http://localhost:8000/health
```
Expect `ok : True`.

---

## C. TEST the /scope endpoint (second terminal, venv not required)

Use your token from `.env` (`INBOUND_TOKEN`). PowerShell-native, no escaping pain:
```powershell
$body = @{
    supplierId    = "001TEST"
    legalName     = "Boreal Refining Oy"
    country       = "Finland"
    commodity     = "Refined cobalt sulfate"
    jurisdictions = @("US buyer", "FI supplier", "DRC upstream")
} | ConvertTo-Json

Invoke-RestMethod -Uri "http://localhost:8000/scope" -Method Post `
  -Headers @{ Authorization = "Bearer change-me-to-a-long-random-string-7f3a9c12b8e64d05" } `
  -ContentType "application/json" -Body $body | ConvertTo-Json -Depth 5
```
Expect JSON with `riskTier`, `riskSummary`, and a `checklist`.

---

## D. ADDING NEW POLICIES (do this whenever the corpus changes)

**1.** Make sure containers are up (Section B steps 1–3) and venv is active (step 4).

**2.** Drop your `.md` / `.txt` / `.pdf` / `.docx` files into:
```
C:\Users\johns\supplier-compliance-local\policies\
```
(one regulation per file = cleanest domain tagging)

**3.** Re-run ingestion:
```powershell
python ingest_policies.py
```
Re-running is safe — the upsert updates existing chunks instead of duplicating them.

**4.** Confirm the rows landed:
```powershell
docker exec compliance-db psql -U compliance -d compliance -c "SELECT source, count(*) AS chunks, domain FROM policy_chunk GROUP BY source, domain ORDER BY source;"
```

**5.** No need to restart `uvicorn` — it reads the DB fresh on every request, so new
chunks are searchable immediately.

**To remove a document's chunks** (e.g. an outdated policy):
```powershell
Remove-Item C:\Users\johns\supplier-compliance-local\policies\<file-name>
docker exec compliance-db psql -U compliance -d compliance -c "DELETE FROM policy_chunk WHERE source = '<file-name>';"
```

---

## E. END OF SESSION (optional)

- Stop the service: `Ctrl + C` in the uvicorn terminal.
- Stop containers (keeps all data): `docker compose stop`
- Or just close Docker Desktop — data in `pgdata` survives.

Next session, start again from Section B.

---

## F. WHEN YOU'RE READY FOR SALESFORCE (later)

Only then do you need the tunnel. In its own terminal, with the service running:
```powershell
cloudflared tunnel --url http://localhost:8000
```
Copy the printed `https://<something>.trycloudflare.com` URL into the Salesforce
Named Credential. Note: this free tunnel gives a **new URL every time** you start it,
so you'll update the Named Credential whenever you restart it.

---

## Troubleshooting quick hits

| Symptom | Cause / Fix |
|---------|-------------|
| `No module named 'paramiko'` (or fastapi, etc.) | You're not in the venv. Run `.venv\Scripts\activate` (prompt shows `(.venv)`), or call `.venv\Scripts\python.exe ...` directly. |
| `(base)` in your prompt | That's Anaconda's env, not the project venv. Activate `.venv`. |
| `curl ... cannot convert ... IDictionary` | PowerShell's `curl` is `Invoke-WebRequest`. Use `curl.exe --%` or the `Invoke-RestMethod` block in Section C. |
| `docker` command hangs / "cannot connect" | Docker Desktop isn't running. Open it, wait for "Engine running". |
| `/scope` returns 401 | Token mismatch — the `Bearer` value must equal `INBOUND_TOKEN` in `.env`. |
| `/scope` returns empty checklist | No chunks ingested. Run `python ingest_policies.py` and check Section D step 4. |
