# Vendor Onboarding — End-to-End Sequence Diagrams

Two views of the same flow:
1. **High-level** — for stakeholders (intake → upload → AI review → CRM sync).
2. **Detailed** — the agentic engine steps + human gates.

> Paste either ```mermaid``` block into draw.io (Arrange → Insert → Advanced → Mermaid).

---

## 1. High-level (stakeholder view)

```mermaid
sequenceDiagram
    autonumber
    actor Supplier as Supplier Requestor
    participant Site as Public Intake Site
    participant SF as Salesforce (Veera App)
    actor Proc as Procurement Manager
    participant AI as AI Compliance Engine
    actor Analyst as Risk Analyst

    Note over Supplier,Site: Public, supplier-facing
    Supplier->>Site: Open emailed intake link
    Supplier->>Site: Fill company details + Save
    Site->>SF: Create Supplier Account

    Note over SF,Analyst: Internal (Veera app)
    Proc->>SF: Open new supplier
    SF->>AI: Generate document checklist (risk scope)
    AI-->>SF: Checklist + risk tier
    Proc->>Supplier: Email document request

    Supplier->>SF: Upload documents
    SF->>AI: AI review (extract + judge each doc)
    AI-->>SF: Structured summary + verdict (CRM sync)

    SF->>AI: Registry & watchlist screening
    AI-->>SF: Screening results (CRM sync)
    Proc->>Analyst: Hand off for review
    Analyst->>SF: Validate + decision & route
    SF-->>Proc: Onboarding complete / rejected
```

---

## 2. Detailed (agentic engine + human gates)

```mermaid
sequenceDiagram
    autonumber
    actor Supplier
    participant Site as Public Intake Site
    participant SF as Salesforce (Veera App)
    actor Proc as Procurement Mgr
    participant Eng as FastAPI Engine
    participant Graph as Agent Supervisor (LangGraph)
    participant RAG as RAG / pgvector
    participant Ext as External Registries
    actor Analyst

    %% --- Self-service intake ---
    Supplier->>Site: Fill intake + Save
    Site->>SF: Create Account (self-registered)

    %% --- Case starts: intake/scope agent ---
    Proc->>SF: Open supplier in Veera
    SF->>Eng: POST /cases (start case)
    Eng->>Graph: intake/scope agent
    Graph->>RAG: retrieve policy clauses
    RAG-->>Graph: ranked clauses
    Graph-->>Eng: scope + checklist + risk tier
    Eng-->>SF: case view (timeline + next action)
    Note over SF,Proc: GATE 1 — Procurement confirms scope
    Proc->>SF: Confirm scope
    SF->>Eng: POST /resume (oversight level)

    %% --- Screening agent (parallel calls) ---
    Eng->>Graph: screening agent
    par identity + sanctions in parallel
        Graph->>Ext: GLEIF identity
    and
        Graph->>Ext: Sanctions / watchlist
    end
    Ext-->>Graph: signals
    Graph-->>Eng: screening verdict (flag never auto-clears)

    %% --- Document review agent (re-entrant) ---
    Supplier->>SF: Upload document(s)
    SF->>Eng: POST /assess per new doc
    Eng->>Graph: documents agent (dedup, only new)
    Graph->>RAG: clauses for this doc
    Graph-->>Eng: extracted fields + structured summary + verdict
    Eng-->>SF: persist to Compliance_Assessment__c

    %% --- Synthesis + routing ---
    Graph->>Graph: synthesis (weighted score + tier)
    Graph->>Graph: routing (tier -> approver + SLA)
    Eng-->>SF: recommended tier + approver
    Note over SF,Analyst: GATE 2 — Analyst signs off
    Analyst->>SF: Approve / reject / needs-info
    SF->>Eng: POST /resume (decision)
    Eng-->>SF: final status (CRM sync)
```

---

## Notes

- **Public vs internal boundary**: only the intake page is public/guest; every
  downstream step runs inside Salesforce (Veera app) + the engine.
- **CRM sync points**: each AI result (checklist, doc summary, screening, decision)
  is written back to Salesforce records (`Account`, `Compliance_Assessment__c`).
- **Two human gates**: Gate 1 (procurement confirms scope) and Gate 2 (analyst signs
  off); a flagged case can never auto-clear.
