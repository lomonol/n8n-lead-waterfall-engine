-- Run once on an existing deployment, before activating the workflows.

-- Dedupe is enforced by the database, not just a check-then-insert.
-- Workflow 01 routes the resulting insert error to "Drop Duplicate Domain".
create unique index if not exists outbound_companies_domain_key
  on outbound_companies (lower(domain));

-- Leftover name from an earlier email provider; the column now stores the Resend message id.
alter table outbound_contacts rename column instantly_lead_id to resend_message_id;
