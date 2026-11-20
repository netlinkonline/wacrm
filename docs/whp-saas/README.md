# WHP WhatsApp SaaS Foundation

WHP-specific architecture and implementation documentation layered additively on WACRM.

- WHP repository: https://github.com/netlinkonline/wacrm
- Development branch: `whp-saas-foundation`
- Baseline commit: `6dbeb5bf94d4cf01be351272d0d45b64b1a684d4`
- Stack: Next.js 16, React 19, TypeScript, Supabase Auth and PostgreSQL RLS.

## Architecture decisions

1. Preserve existing WACRM functionality and MIT license notices.
2. Add a distinct WHP SaaS tenant/organization model; do not silently equate legacy WACRM accounts with SaaS tenants.
3. Use one PostgreSQL database with tenant-aware constraints and row-level security.
4. Separate WHP platform roles from tenant roles.
5. WHMCS 9.1.0 remains billing authority; integrate through signed, idempotent API calls, never direct database coupling.
6. Use official Meta WhatsApp Cloud API. Embedded Signup and production permissions are separate launch gates.
7. Execute campaigns and automations through durable background workers, not synchronous requests.
8. Keep initial changes additive. Do not migrate existing customer data until compatibility and rollback plans are reviewed.

## Tenant roles

`owner`, `admin`, `agent`, `viewer`.

## Platform roles

`super_admin`, `billing_admin`, `support_admin`, `technical_admin`, `analyst`.

Platform privileges must never be inferred from tenant membership. Privileged support access must be authorized, time-bound and audited.

## Initial phases

1. Source/dependency/migration audit and reproducible staging baseline.
2. Tenant organizations, memberships, roles, RLS and cross-tenant security tests.
3. Meta WABA/number mapping, token protection, webhook verification and messaging tests.
4. Plans, entitlements, usage ledger, suspension controls and WHP Super Admin.
5. WHMCS provisioning module and end-to-end billing tests.
6. Reliability, security, backup/restore, load tests and controlled pilot.

## Acceptance

No phase is complete based on UI appearance alone. Require automated tests and recorded evidence, especially cross-tenant isolation, Meta webhook idempotency, campaign recovery, WHMCS lifecycle and backup restoration.
