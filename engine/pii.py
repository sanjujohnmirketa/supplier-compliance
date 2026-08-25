"""
pii.py — tokenize PII so real PII never reaches the external LLM.

Microsoft Presidio detects sensitive entities in supplier documents and we
replace them with stable tokens ([PERSON_1], [US_BANK_NUMBER_1], ...) BEFORE the
text is sent to OpenAI. Compliance-relevant content (dates, issuer org, country,
cert numbers) is deliberately NOT tokenized so the LLM can still judge.
"""
from functools import lru_cache

# Real PII we tokenize. We exclude DATE_TIME / LOCATION / ORG / URL on purpose —
# those carry compliance signal (expiry dates, issuer, country of origin).
PII_ENTITIES = [
    "PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER", "US_SSN", "US_ITIN",
    "US_BANK_NUMBER", "IBAN_CODE", "CREDIT_CARD", "US_DRIVER_LICENSE",
    "US_PASSPORT", "CRYPTO", "IP_ADDRESS",
]

@lru_cache(maxsize=1)
def _analyzer():
    from presidio_analyzer import AnalyzerEngine
    from presidio_analyzer.nlp_engine import NlpEngineProvider
    provider = NlpEngineProvider(nlp_configuration={
        "nlp_engine_name": "spacy",
        "models": [{"lang_code": "en", "model_name": "en_core_web_sm"}],
    })
    return AnalyzerEngine(nlp_engine=provider.create_engine())

def tokenize_pii(text: str):
    """Return (tokenized_text, mapping{token: original}). Same value -> same token."""
    if not text or not text.strip():
        return text, {}

    results = _analyzer().analyze(text=text, entities=PII_ENTITIES, language="en")

    # Assign tokens in reading order for natural numbering
    value_to_token, mapping, counters = {}, {}, {}
    for r in sorted(results, key=lambda x: x.start):
        original = text[r.start:r.end]
        if original not in value_to_token:
            counters[r.entity_type] = counters.get(r.entity_type, 0) + 1
            token = f"[{r.entity_type}_{counters[r.entity_type]}]"
            value_to_token[original] = token
            mapping[token] = original

    # Replace from the end so earlier offsets stay valid
    out = text
    for r in sorted(results, key=lambda x: x.start, reverse=True):
        original = text[r.start:r.end]
        out = out[:r.start] + value_to_token[original] + out[r.end:]

    return out, mapping


def detokenize(value, mapping: dict):
    """Reverse tokenize_pii's substitution in the MODEL'S OWN OUTPUT.

    The LLM only ever sees tokenized text (e.g. "[PERSON_1]") — if it echoes a
    token back in its verdict/summary/reasons (common: it copies a name/id
    straight out of the document into its explanation), that raw token must
    not reach the human-facing UI. Applies recursively so it's safe to call on
    an entire parsed JSON response (dict/list/str) in one shot.
    """
    if not mapping:
        return value
    if isinstance(value, str):
        out = value
        for token, original in mapping.items():
            out = out.replace(token, original)
        return out
    if isinstance(value, dict):
        return {k: detokenize(v, mapping) for k, v in value.items()}
    if isinstance(value, list):
        return [detokenize(v, mapping) for v in value]
    return value
