# Case Study: Multi-Stage Lead Waterfall

**Five chained n8n workflows that turn a raw list of businesses into verified, qualified, personalised outreach, and sort the replies, with a ledger that guarantees no company is processed twice.**

![n8n](https://img.shields.io/badge/n8n-5%20workflows%20%2B%20DLQ-EA4B71?style=flat-square) ![Local LLM](https://img.shields.io/badge/LLM-Ollama%20(local%2C%20Qwen%202.5)-blue?style=flat-square) ![Supabase](https://img.shields.io/badge/ledger-Supabase-3ECF8E?style=flat-square) ![Status](https://img.shields.io/badge/status-portfolio%20build-lightgrey?style=flat-square)

| | |
|---|---|
| **Type** | Portfolio build (reference implementation, not a client engagement) |
| **My role** | Sole designer and builder: pipeline design, scoring rubric, prompt and schema design, data model, compliance handling |
| **Scale** | 6 workflows (5 stages plus a global error handler), 75 nodes, 4 Supabase tables, 3 enrichment/verification providers |
| **Stack** | n8n, Ollama (Qwen 2.5, local), Supabase, Airtable, Apify, Tomba, Reoon, Resend, Gmail, Slack |
| **Status** | Runs on sample data. Has not sent real campaigns. Known defects are listed at the bottom. |

> **If you only read one section:** [Why this is interesting](#why-this-is-interesting) and [What I would fix next](#what-i-would-fix-next).

---

## The problem

Outbound only works on clean data, and most lead lists are not clean. The same company appears three times. Half the addresses bounce. Many companies were never a fit. Sending to all of them wastes effort, burns sender reputation, and, when someone replies "remove me" and nothing happens, creates real compliance risk.

The fix is not a better email. It is a **pipeline that refuses to waste effort**: reject duplicates before they cost anything, judge fit before spending enrichment credits, verify every address before sending, and make opt-outs automatic.

## Outcome

- A company is processed **once**, enforced by a database ledger keyed on its domain.
- Fit is judged by a **local LLM** (no per-token cost, no lead data leaves my infrastructure) against an explicit 0-100 rubric, and only qualifying companies reach the paid enrichment stage.
- Contacts come from a **waterfall of providers** and every address is verified before it can be sent to. Failures are written to a suppression table, not retried forever.
- Replies are classified by intent; hot leads go to Slack for a human, unsubscribes are suppressed automatically.

## Why this is interesting

1. **The funnel is ordered by cost.** Free checks first (dedupe), then local-LLM scoring, then paid enrichment and verification, then email. Each stage protects the next from wasted spend.
2. **Five small workflows, not one giant one.** Each stage is independently testable, replaceable and re-runnable, chained with Execute Workflow.
3. **Compliance is a pipeline stage, not an afterthought.** Suppression is written by both the verifier and the reply triager.
4. **I audited it and report what I found.** Including one place where I let the model make a decision that should be code.

---

## Architecture

```mermaid
flowchart LR
  subgraph P1[1. Ingestion gatekeeper]
    S[Weekly schedule<br/>Apify Maps search] --> W
    WH[POST /lead-intake] --> V{Secret valid?}
    V -- no --> U[401]
    V -- yes --> W[Normalize domains]
    W --> D{Domain in ledger?}
    D -- yes --> X[Drop duplicate]
    D -- no --> I[(Insert, status: seeded)]
  end
  I --> P2
  subgraph P2[2. AI website auditor]
    J[Fetch site as markdown] --> DS[Distill event signal<br/>keyword filter, 2,500 char cap]
    DS --> L[Local LLM: rubric score 0-100,<br/>pain point, icebreaker]
    L --> Q{Qualified?}
    Q -- no --> DQ[(status: disqualified)]
    Q -- yes --> QS[(status: qualified + Airtable cockpit)]
  end
  QS --> P3
  subgraph P3[3. Waterfall enrichment]
    T[Tomba domain search] --> TF{Found a contact?}
    TF -- no --> A[Apify contact scraper]
    TF -- yes --> N[Normalize]
    A --> N
    N --> R[Reoon verification]
    R --> RV{Deliverable?}
    RV -- no --> SUP[(Suppression list)]
    RV -- yes --> C[(Insert verified contact)]
  end
  C --> P4[4. Icebreaker + campaign engine<br/>build payload, send via Resend, log]
  P4 -.reply.-> P5
  subgraph P5[5. Reply triage]
    G[Gmail trigger / reply webhook] --> F{Campaign reply?}
    F --> K[Local LLM: intent]
    K --> RT{Route}
    RT -- interested --> H[(Ledger + Airtable) + Slack approval card]
    RT -- unsubscribe --> US[(Auto-suppress + mark unsubscribed)]
    RT -- other --> LG[(Log)]
  end
```

### Stage by stage

| # | Workflow | What it does | Why it is built this way |
|---|---|---|---|
| 1 | **Ingestion gatekeeper** | Two entry points: a weekly scheduled Maps search and an authenticated webhook. Validates the secret, lowercases the domain and strips protocol and `www.`, checks Supabase for that domain, inserts new ones with status `seeded`. | Dedupe happens before any scrape, LLM or paid API call. The scheduled search pipes its results into the same webhook, so there is exactly one door. |
| 2 | **AI website auditor** | Fetches each `seeded` company's site as markdown, reduces it to the paragraphs that matter, scores it with a local LLM, writes `qualified` or `disqualified`, syncs qualified accounts to an Airtable cockpit. | Scoring before enrichment means paid contact lookups only run on companies that fit. |
| 3 | **Waterfall enrichment** | For each qualified account: domain search, fall back to a contact-page scraper if that finds nothing, then verify the address. Valid becomes a contact; invalid is suppressed. | One provider failing or returning nothing does not stop the run, and no unverified address reaches the sender. |
| 4 | **Campaign engine** | Loads verified contacts, joins the company dossier (including the icebreaker the auditor wrote), builds the payload, sends through Resend, stamps the campaign ID back on the contact, upserts the cockpit row. | The personalisation was generated and stored in stage 2, so sending is a cheap deterministic step. |
| 5 | **Reply triage** | Receives replies from a webhook or a Gmail trigger, ignores personal mail, classifies intent, routes. | Replies arrive from several sources; one normaliser feeds one classifier. |
| - | **Global error handler** | Logs failures to a dead-letter table and alerts DevOps. | Unattended pipelines must say when they break. |

---

## Deep dives

### The scoring rubric

The auditor does not ask "is this a good lead?". It scores against an explicit rubric the model must follow:

| Signal | Points |
|---|---|
| Private event rooms or dedicated banquet space | +30 |
| Group capacity of at least 20 seated or 40 standing | +20 |
| Dedicated events or catering menu, or buyout packages | +20 |
| Inquiry form or event contact present | +10 |
| Relies on manual PDF quotes or generic email, no instant booking | +20 |
| Fast-casual or counter-serve only | forced to 0-25 |

The model returns a typed object: `icp_score`, `icp_qualified`, `online_booking_present`, `catering_capabilities[]`, `primary_pain_point`, `icebreaker_angle`, `reasoning`. The rubric makes scores comparable across thousands of runs; the `reasoning` field makes any single score auditable.

### Cutting tokens before the model sees them

A raw homepage is mostly navigation, cookie banners and footers. A small Code node splits the markdown into paragraphs, keeps only those containing event-related keywords (private, banquet, buyout, capacity, inquiry, and similar), drops obvious junk (cookie notices, privacy policy, "all rights reserved"), and stops at about **2,500 characters**. If nothing relevant is found it falls back to the first 1,500. This keeps a small local model fast and keeps it from scoring a cookie banner.

### The prompt fixes a perspective problem

A common failure in prompts like this: the model writes marketing copy for the *venue's customers* instead of a pitch to the *venue owner*. The system prompt states sender and recipient explicitly, forbids both failure modes by name, and includes good and bad few-shot icebreakers with the reason each bad one is bad. Naming the failure in the prompt is cheaper than debugging it in output.

### The waterfall order

Per account: **Tomba** domain search first; if it returns nothing, **Apify** contact-info scraper on the site; either result is normalised into one shape and then **Reoon** verifies it. `valid` and `catch_all` count as sendable. Anything else is written to the suppression table with the reason (`Deliverability verification failed: <status>`), including accounts where no contact was found at all. One normaliser, one verifier, two sources.

### Reply triage and compliance

The classifier returns one of four intents, `INTERESTED`, `OBJECTION`, `OOO`, `UNSUBSCRIBE`, plus urgency and a two-sentence draft reply. A Switch routes each:

- **Interested:** written to the replies ledger and Airtable, and a Slack card goes to a human with the draft. The model drafts; a person sends.
- **Unsubscribe:** the sender is written to the suppression table and marked unsubscribed in Airtable, immediately and with no human step.
- **Anything else:** logged.

Opt-out handling being automatic is the compliance-critical part of the design.

---

## Decision log

### Decision 1: a local LLM for scoring
- **Options:** hosted frontier model vs local Qwen 2.5 on Ollama.
- **Chose local.** Scoring runs on every seeded lead, most of which get rejected, so per-token cost scales with the *worst* part of the funnel. Local also means scraped lead data never leaves my server.
- **Trade-off:** a small model follows a rubric less reliably than a large one, so the structured schema and explicit rubric carry more weight, and I accept occasional mis-scores.

### Decision 2: a database ledger, not workflow memory
- Dedupe lives in Supabase keyed on domain, so it survives restarts and is shared by every stage and every entry point. Cost: a lookup per lead.

### Decision 3: waterfall with a single verifier
- Two sources feed one Reoon verification step. Cost: verification credits are spent on every candidate; benefit: nothing unverified reaches the sender regardless of source.

### Decision 4: one stage per workflow
- Independently testable and re-runnable. Cost: more workflows to import and link, and Execute Workflow IDs to manage (these are placeholders in this export).

### Decision 5: suppression as a shared table
- Both the verifier and the reply triager write to the same `outbound_suppression` table, so there is one source of truth for "never contact".

---

## Failure modes I designed for

| What goes wrong | What happens |
|---|---|
| Same company submitted twice | Dropped at the ledger before any cost |
| Unauthorised caller | `401` before any processing |
| Site has no useful content | Distiller falls back to the first 1,500 characters; the model scores what it has |
| First enrichment provider finds nothing | Falls through to the scraper |
| Email fails verification | Suppressed with a reason, never sent to |
| Prospect asks to be removed | Auto-suppressed and marked in the CRM |
| Any workflow throws | Global error handler logs to DLQ and alerts DevOps |

## Data model

| Table | Purpose |
|---|---|
| `outbound_companies` | The ledger: `domain` (unique key in practice), `company_name`, `website_url`, `city`, `state`, `vertical`, `status` (`seeded`, `qualified`, `disqualified`), `icp_score`, dossier fields |
| `outbound_contacts` | Verified contacts: `company_id`, name, `email`, `job_title`, `enrichment_source`, `deliverability_status`, `assigned_campaign_id`, `resend_message_id` |
| `outbound_suppression` | Never-contact list: `email_or_domain`, `type`, `reason` |
| `outbound_inbound_replies` | Classified replies: `prospect_email`, `sentiment`, `reply_body`, `ai_draft_response` |

Airtable holds the human-facing cockpit (qualified accounts, hot leads) and the DLQ.

## Testing and verification

**No measured results are recorded yet.** I will not quote an accuracy or conversion figure I have not measured. What exists:

- [`samples/lead-intake.json`](samples/lead-intake.json) is a ready payload for stage 1.
- Suggested checks: submit the same domain twice (second must drop); submit a fast-casual site (should score 0-25); submit an unsubscribe-style reply (should suppress without human input).
- Pending: a labelled set of about 30 venues to report scoring agreement with a manual judgement, and a labelled set of replies to report classifier accuracy.

## What I would fix next

Findings from auditing my own build, in priority order:

1. ~~**Campaign sends have no human gate or daily cap.**~~ **Added to the workflow, not yet run-tested.** After the suppression check, one approval email (Gmail send-and-wait) lists the whole batch; nothing sends unless a person approves. A Code node then applies a per-day cap (`DAILY_CAP = 5`, counted in workflow static data) before the send. Known limits: static data only persists in production runs, so the cap does not carry across manual test runs; and the count is taken at approval time, so a send that later fails still uses up cap. Set `sendTo` on the approval node to your own address.
2. ~~**Re-runs can double-send.**~~ **Fixed in the workflow, not yet run-tested.** Stage 4 now loads only contacts where `assigned_campaign_id is null`, so a re-run skips contacts that were already sent.
3. ~~**Suppression is not re-checked at send time.**~~ **Fixed in the workflow, not yet run-tested.** A `Check Suppression List` lookup (email or domain, against `outbound_suppression`) and a `Not Suppressed?` IF now sit between the contact fetch and the send. Suppressed contacts stop there. I could not execute it end to end: the test run would write to the real database and send through Resend, so it was blocked. It is wired and saved, nothing more.
4. ~~**A decision that belongs in code is in the prompt.**~~ **Fixed in the workflow, not yet run-tested.** `icp_qualified` is no longer in the model's output schema. An IF node compares `icp_score >= 70`, as in the [incident platform](https://github.com/lomonol/n8n-ai-incident-escalation-platform).
5. ~~**Dedupe is check-then-insert.**~~ **Fixed, needs one SQL step.** [`schema/migrations.sql`](schema/migrations.sql) adds a unique index on the lowercased domain, and the insert node now sends a conflict error to "Drop Duplicate Domain" instead of failing the run. Until the index exists, the race is still open.
6. ~~**Confidence is returned but unused.**~~ **Fixed in the workflow, not yet run-tested.** `confidence_score` is now required, and a Switch rule sends anything below 0.7 (or missing) to a `needs_human_review` row instead of auto-routing. One deliberate exception: `UNSUBSCRIBE` is matched first and suppresses at any confidence, because wrongly suppressing a lead costs one contact while missing an opt-out is the compliance failure. Limit: the review row is a ledger entry only, with no Slack alert yet.
7. **Shared secret is compared in a node.** *Still open.* The intake secret is hardcoded in two nodes of workflow 01 (the check and the scheduled pipe), and the Apify and Slack tokens are hardcoded in their HTTP nodes. The fix is credentials (a Header Auth credential for the webhook and the pipe, a query-auth one for Apify, a bearer one for Slack), which have to be created in n8n by the account owner. The exported files here contain placeholders, not the live values.
8. ~~**Naming leftovers.**~~ **Fixed.** The reply prompt no longer names a demo persona, the intake normaliser no longer invents a fake sender and subject when a payload is malformed (it used to default to a made-up prospect address, which a mis-parsed unsubscribe could have suppressed), and the `instantly_lead_id` column is renamed `resend_message_id` in the migration and the workflow.

## Configuration and swap-ins

Everything below is a setting or a node swap, not a rewrite. The defaults are what I used because they are free or cheapest, not because the design needs them.

| What | Default here | Change it to |
|---|---|---|
| **Scoring LLM** | Local Qwen 2.5 on Ollama | Any hosted or local model. A larger model follows the rubric more reliably; a hosted one removes the need to run Ollama. |
| **ICP rubric and cut-off** | Event-venue rubric, qualified at 70 or above | Rewrite the prompt for any niche and change the threshold. Nothing else depends on the industry. |
| **Lead source** | Apify Google Maps actor, weekly | Any scraper, CSV upload, or CRM export. Anything that can POST to the intake webhook works. |
| **Contact finder** | Tomba, then Apify contact scraper | Hunter, Apollo, Snov, Dropcontact, or your own scraper. The Normalize step maps any provider to one shape. |
| **Email verifier** | Reoon | ZeroBounce, NeverBounce, Kickbox, MillionVerifier. Change the HTTP node and the "valid" condition. |
| **Sender** | Resend | Gmail, SMTP, Instantly, Smartlead, Mailgun. |
| **Ledger and CRM** | Supabase and Airtable | Postgres, Notion, Sheets, HubSpot. Keep the unique-domain rule. |
| **Content distiller** | Event keywords, 2,500 character cap | Your own keyword list and size limit. |
| **Reply classes** | Interested, objection, out of office, unsubscribe | Add or rename; update the Switch. |
| **Schedule and batch size** | Weekly, 5 places | Any. |

## What this demonstrates

- **Pipeline design ordered by cost**, with idempotency enforced in a database.
- **Local LLM use** with a rubric, a typed schema and pre-processing to control tokens.
- **Multi-provider enrichment** with fallback and verification.
- **Compliance-aware automation**: suppression and opt-out handling built into the flow.
- **Modular workflow architecture** (Execute Workflow chaining) and a shared error handler.
- **Self-audit**: a written list of defects and the fixes.

## Repository

| File | Purpose |
|---|---|
| [`workflows/01-lead-sourcing-ingestion-gatekeeper.json`](workflows/01-lead-sourcing-ingestion-gatekeeper.json) | Ingest, authenticate, normalise, dedupe |
| [`workflows/02-ai-website-auditor-icp-scoring.json`](workflows/02-ai-website-auditor-icp-scoring.json) | Fetch site, distil, score with local LLM, sync |
| [`workflows/03-waterfall-enrichment-deliverability.json`](workflows/03-waterfall-enrichment-deliverability.json) | Contact lookup waterfall and verification |
| [`workflows/04-icebreaker-campaign-engine.json`](workflows/04-icebreaker-campaign-engine.json) | Build payload, send, log |
| [`workflows/05-reply-triage-slack-hitl.json`](workflows/05-reply-triage-slack-hitl.json) | Classify replies, suppress, alert |
| [`workflows/06-error-handler-dlq.json`](workflows/06-error-handler-dlq.json) | Global error handler |
| [`samples/lead-intake.json`](samples/lead-intake.json) | Sample request payload |
| [`schema/migrations.sql`](schema/migrations.sql) | Unique domain index and column rename |

### Run it yourself
1. Import the six workflows into n8n. All are exported **inactive**.
2. Replace every placeholder (`REPLACE_ME`, `YOUR_*`, `WORKFLOW_ID_*`), re-select credentials, and re-link the Execute Workflow nodes and the Error workflow setting to your imported copies.
3. Create the four Supabase tables and the Airtable cockpit, then run [`schema/migrations.sql`](schema/migrations.sql). Pull a Qwen 2.5 model into Ollama.
4. Send the sample payload:

   ```bash
   curl -X POST https://YOUR-N8N-HOST/webhook/lead-intake \
     -H "x-caterflow-secret-key: YOUR_SHARED_SECRET" \
     -H "Content-Type: application/json" \
     -d @samples/lead-intake.json
   ```

### Responsible use
Scraping and cold email are regulated. Respect site terms, include a real opt-out and postal address, honour the suppression list, and check CAN-SPAM, GDPR and PECR for your jurisdiction before sending. This is a pipeline design, not an invitation to send unsolicited bulk mail.

Brand names, people and addresses are fictional demo data. MIT licensed.

*Built by Laurence. Part of a set of four automation case studies: [lead gen and outreach](https://github.com/lomonol/n8n-lead-gen-outreach-engine), [incident platform](https://github.com/lomonol/n8n-ai-incident-escalation-platform), [support and warranty](https://github.com/lomonol/n8n-support-warranty-automation).*
