# WHP WhatsApp SaaS Foundation

WHP-specific architecture and implementation layered additively on WACRM.

- WHP repository: https://github.com/netlinkonline/wacrm
- Development branch: `whp-saas-foundation`
- Baseline commit: `6dbeb5bf94d4cf01be351272d0d45b64b1a684d4`
- Stack: Next.js 16, React 19, TypeScript, Supabase Auth and PostgreSQL RLS.

## Canonical tenant model

The existing WACRM `accounts.id` is the WHP customer-organization/tenant identifier. Do not create a second tenant ID. Existing CRM records already use `account_id`; preserving this identity avoids rewriting contacts, conversations, messages, broadcasts, automations, API keys and webhook ownership.

Migration 061 adds `account_memberships` as the many-to-many membership source of truth and backfills current profiles/account owners. `profiles.account_id/account_role` remain temporarily as a legacy default-account pointer for compatibility. The `is_account_member()` RLS helper now checks active membership rows.

Migration 062 adds membership-aware invitation redemption, role changes, member removal and ownership transfer. Invitation redemption adds the new membership without moving the user's existing workspace or deleting data.

The account selector uses an HTTP-only `wacrm_active_account` cookie. The cookie is only a selector: every request revalidates the account against the authenticated user's active membership. The `/api/account/active` endpoint lists memberships and verifies account selection server-side.

## Architecture decisions

1. Preserve existing WACRM functionality and MIT license notices.
2. Use one PostgreSQL database with tenant-aware constraints and row-level security.
3. Separate WHP platform roles from customer membership roles.
4. WHMCS 9.1.0 remains billing authority; integrate through signed, idempotent API calls, never direct database coupling.
5. Use official Meta WhatsApp Cloud API. Embedded Signup and production permissions are separate launch gates.
6. Execute campaigns and automations through durable background workers, not synchronous requests.
7. Keep migrations additive and preserve legacy account/profile fields until all application routes have been migrated and regression-tested.

## Customer roles

`owner`, `admin`, `agent`, `viewer`.

## Platform roles

`super_admin`, `billing_admin`, `support_admin`, `technical_admin`, `analyst`.

Platform privileges are not inferred from customer membership. Privileged support access must be authorized, time-bound and audited.

## Remaining delivery phases

1. Finish account membership UI/API migration and automated cross-tenant RLS tests.
2. Normalize multiple WABAs and phone numbers per account; migrate legacy `whatsapp_config` with compatibility.
3. Build WHP Super Admin, plans, entitlements, limits and usage enforcement.
4. Build WHMCS 9.1.0 provisioning module and end-to-end billing tests.
5. Harden Meta Embedded Signup, webhooks, messaging, queues and recovery.
6. Complete security, load, backup/restore and controlled pilot validation.

## Release gates

No phase is complete based on UI appearance alone. Require automated tests and recorded evidence, especially cross-tenant isolation, Meta webhook idempotency, campaign recovery, WHMCS lifecycle and backup restoration. Migrations 061/062 are committed but must be applied and tested in isolated staging before production use.
