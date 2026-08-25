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


# The domain expert's clinical-lab/pharmacy/supplement set — named explicitly
# rather than matched by a "std_supplier_" prefix, because that prefix is also
# used by pre-existing AUTOMOTIVE files (std_supplier_quality_requirements.md,
# std_supplier_information_security.md, std_supplier_financial_governance.md —
# all "Meridian Drive Systems" branded, IATF/TISAX/GLEIF-grounded, nothing to
# do with healthcare). A prefix-based rule swept those into the healthcare
# corpus by accident; an explicit list can't make that mistake again.
HEALTHCARE_STD_SUPPLIER_FILES = {
    "std_supplier_clia_certification.md",
    "std_supplier_cap_accreditation.md",
    "std_supplier_usp795_nonsterile_compounding.md",
    "std_supplier_usp797_sterile_compounding.md",
    "std_supplier_usp800_hazardous_drugs.md",
    "std_supplier_dea_registration.md",
    "std_supplier_21cfr111_dietary_supplement_gmp.md",
    "std_supplier_nsf_gmp_certification.md",
    "std_supplier_hipaa_baa.md",
    "std_supplier_device_diagnostics_qms.md",
    "std_supplier_health_it_digital.md",
    "std_supplier_provider_credentialing.md",
    "std_supplier_payer_delegation.md",
    "std_supplier_behavioral_health_part2.md",
}


def industry_from_filename(name: str) -> str:
    """Convention used across the demo corpus: a `<industry>_` filename prefix
    tags which customer/industry corpus the file belongs to (e.g.
    `healthcare_privacy_security.md`). Files with no recognized prefix default
    to "automotive", matching the original single-industry corpus that
    predates this convention."""
    lower = name.lower()
    if lower in HEALTHCARE_STD_SUPPLIER_FILES:
        return "healthcare"
    if lower.startswith("healthcare_"):
        return "healthcare"
    if lower.startswith("automotive_"):
        return "automotive"
    return "automotive"


# guess_domain() has no healthcare-specific keyword vocabulary yet (that's a
# separate future step — expanding DOMAIN_KEYWORDS/Compliance_Domain__mdt with
# per-industry terms). Until then, bulk-ingest scripts need an explicit
# filename -> domain override for files whose auto-detected domain is wrong
# (e.g. healthcare_general.md's SAQ/insurance/continuity content scored
# stronger on "cyber" keywords than "general" ones). Mirrors the domainHint
# override the single-file /policy/ingest endpoint already exposes.
DOMAIN_OVERRIDE_BY_FILENAME = {
    "healthcare_general.md": "general",
    # Split from the old healthcare_device_material_compliance.md, which
    # covered BOTH device clearance/UDI and material/SDS content — guess_domain()
    # could only pick one winner (it started flipping to device_diagnostics_qms
    # once that domain's keywords were added, silently starving the material
    # content). Pinned explicitly now that each half is its own file.
    "healthcare_device_regulatory_clearance.md": "device_diagnostics_qms",
    "healthcare_material_safety.md": "material",
    # Explicit overrides for the clinical-lab set: CLIA and CAP text
    # cross-reference each other heavily (each doc mentions the other's
    # keywords), so keyword-scoring alone risks misfiling one into the
    # other's domain. Filename is the reliable signal here, not content.
    "std_supplier_clia_certification.md": "clinical_lab_cert",
    "std_supplier_cap_accreditation.md": "clinical_lab_accred",
    "std_supplier_usp795_nonsterile_compounding.md": "pharmacy_compound",
    "std_supplier_usp797_sterile_compounding.md": "pharmacy_compound",
    "std_supplier_usp800_hazardous_drugs.md": "pharmacy_compound",
    "std_supplier_dea_registration.md": "pharmacy_compound",
    "std_supplier_21cfr111_dietary_supplement_gmp.md": "supplement_gmp",
    "std_supplier_nsf_gmp_certification.md": "supplement_gmp",
    "std_supplier_hipaa_baa.md": "cyber",
    "std_supplier_device_diagnostics_qms.md": "device_diagnostics_qms",
    "std_supplier_health_it_digital.md": "health_it_digital",
    "std_supplier_provider_credentialing.md": "provider_credentialing",
    "std_supplier_payer_delegation.md": "payer_delegation",
    "std_supplier_behavioral_health_part2.md": "behavioral_health_part2",
}


def domain_override_for(name: str):
    return DOMAIN_OVERRIDE_BY_FILENAME.get(name)


def main():
    print(f"Connecting to SFTP {SFTP_USER}@{SFTP_HOST}:{SFTP_PORT}{SFTP_DIR} ...")
    files = fetch_files()
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
