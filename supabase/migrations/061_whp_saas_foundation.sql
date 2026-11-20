-- WHP SaaS foundation — canonical account tenant model
-- Replaces the un-applied prototype migration 061. The existing WACRM
-- accounts.id remains the tenant identifier so existing business rows,
-- RLS policies, API keys and webhook ownership remain stable.
--
-- Safe rollout: additive membership + SaaS metadata. profiles.account_id
-- and profiles.account_role remain as a compatibility/default-account
-- pointer until all application routes are migrated. No customer rows
-- are moved, deleted or rewritten.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- One user can own multiple customer accounts in a SaaS. Remove the
-- legacy one-account-per-owner restriction; account membership is now
-- represented by account_memberships.
DROP INDEX IF EXISTS public.idx_accounts_one_per_owner;

CREATE TABLE IF NOT EXISTS public.account_memberships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.account_role_enum NOT NULL DEFAULT 'viewer',
  status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('invited','active','suspended','removed')),
  invited_by_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  joined_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, user_id),
  UNIQUE (account_id, id)
);

CREATE INDEX IF NOT EXISTS idx_account_memberships_user_status
  ON public.account_memberships(user_id, status);
CREATE INDEX IF NOT EXISTS idx_account_memberships_account_status
  ON public.account_memberships(account_id, status);

-- Exactly one active owner per organization. Ownership transfer demotes
-- the current owner before promoting the new one in the same transaction.
CREATE UNIQUE INDEX IF NOT EXISTS idx_account_memberships_one_active_owner
  ON public.account_memberships(account_id)
  WHERE status = 'active' AND role = 'owner';

-- Backfill current single-account membership without changing profiles.
INSERT INTO public.account_memberships
  (account_id, user_id, role, status, joined_at)
SELECT p.account_id, p.user_id, p.account_role, 'active', p.created_at
FROM public.profiles p
WHERE p.account_id IS NOT NULL
  AND p.account_role IS NOT NULL
ON CONFLICT (account_id, user_id) DO UPDATE
SET role = EXCLUDED.role,
    status = 'active',
    joined_at = COALESCE(account_memberships.joined_at, EXCLUDED.joined_at);

-- Every existing account owner must have an owner membership, including
-- any account whose owner profile was not present in the initial join.
INSERT INTO public.account_memberships
  (account_id, user_id, role, status, joined_at)
SELECT a.id, a.owner_user_id, 'owner', 'active', a.created_at
FROM public.accounts a
ON CONFLICT (account_id, user_id) DO UPDATE
SET role = 'owner', status = 'active';

ALTER TABLE public.account_memberships ENABLE ROW LEVEL SECURITY;

-- Replace the legacy profile-based membership predicate. Existing
-- application policies continue calling the same function signature.
CREATE OR REPLACE FUNCTION public.is_account_member(
  target_account_id UUID,
  min_role public.account_role_enum DEFAULT 'viewer'
) RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.account_memberships m
    WHERE m.account_id = target_account_id
      AND m.user_id = (SELECT auth.uid())
      AND m.status = 'active'
      AND CASE m.role
        WHEN 'owner' THEN 4
        WHEN 'admin' THEN 3
        WHEN 'agent' THEN 2
        WHEN 'viewer' THEN 1
      END >= CASE min_role
        WHEN 'owner' THEN 4
        WHEN 'admin' THEN 3
        WHEN 'agent' THEN 2
        WHEN 'viewer' THEN 1
      END
  );
$$;

ALTER FUNCTION public.is_account_member(UUID, public.account_role_enum) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.is_account_member(UUID, public.account_role_enum) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_account_member(UUID, public.account_role_enum) TO authenticated, service_role;

-- A user can see only memberships in accounts they belong to. No direct
-- client writes: invitations and membership changes use audited RPC/API.
DROP POLICY IF EXISTS account_memberships_select ON public.account_memberships;
CREATE POLICY account_memberships_select
  ON public.account_memberships FOR SELECT TO authenticated
  USING (
    user_id = (SELECT auth.uid())
    OR public.is_account_member(account_id, 'admin')
  );

-- SaaS/platform roles are independent of customer membership roles.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'whp_platform_role') THEN
    CREATE TYPE public.whp_platform_role AS ENUM
      ('super_admin','billing_admin','support_admin','technical_admin','analyst');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.whp_platform_roles (
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.whp_platform_role NOT NULL,
  granted_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_at TIMESTAMPTZ,
  PRIMARY KEY (user_id, role)
);
ALTER TABLE public.whp_platform_roles ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.whp_is_platform_role(
  p_allowed public.whp_platform_role[] DEFAULT ARRAY['super_admin','technical_admin']::public.whp_platform_role[]
) RETURNS BOOLEAN
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.whp_platform_roles r
    WHERE r.user_id = (SELECT auth.uid())
      AND r.revoked_at IS NULL
      AND r.role = ANY(p_allowed)
  );
$$;
ALTER FUNCTION public.whp_is_platform_role(public.whp_platform_role[]) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.whp_is_platform_role(public.whp_platform_role[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.whp_is_platform_role(public.whp_platform_role[]) TO authenticated;

DROP POLICY IF EXISTS whp_platform_roles_read_self ON public.whp_platform_roles;
CREATE POLICY whp_platform_roles_read_self
  ON public.whp_platform_roles FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()) OR public.whp_is_platform_role());

-- Plan catalog is global platform configuration. Customers may read active
-- plans; writes are reserved for trusted platform services.
CREATE TABLE IF NOT EXISTS public.whp_plans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE CHECK (code ~ '^[a-z0-9][a-z0-9_-]{1,63}$'),
  name TEXT NOT NULL,
  description TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  entitlements JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.whp_plans ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS whp_plans_read_active ON public.whp_plans;
CREATE POLICY whp_plans_read_active ON public.whp_plans
  FOR SELECT TO authenticated
  USING (is_active OR public.whp_is_platform_role());

-- WHMCS remains billing source of truth. account_id points to the existing
-- WACRM account tenant; no second tenant identity is introduced.
CREATE TABLE IF NOT EXISTS public.whp_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE RESTRICT,
  plan_id UUID NOT NULL REFERENCES public.whp_plans(id) ON DELETE RESTRICT,
  status TEXT NOT NULL CHECK (status IN
    ('pending','trial','active','past_due','grace','suspended','cancelled','terminated')),
  billing_provider TEXT NOT NULL DEFAULT 'whmcs' CHECK (billing_provider = 'whmcs'),
  whmcs_client_id BIGINT,
  whmcs_service_id BIGINT UNIQUE,
  whmcs_product_id BIGINT,
  whmcs_invoice_id BIGINT,
  starts_at TIMESTAMPTZ,
  current_period_starts_at TIMESTAMPTZ,
  current_period_ends_at TIMESTAMPTZ,
  next_due_at TIMESTAMPTZ,
  suspended_at TIMESTAMPTZ,
  terminated_at TIMESTAMPTZ,
  last_synced_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_whp_subscriptions_account_status
  ON public.whp_subscriptions(account_id, status);
ALTER TABLE public.whp_subscriptions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS whp_subscriptions_read_owner ON public.whp_subscriptions;
CREATE POLICY whp_subscriptions_read_owner ON public.whp_subscriptions
  FOR SELECT TO authenticated
  USING (
    public.is_account_member(account_id, 'owner')
    OR public.whp_is_platform_role(ARRAY['super_admin','billing_admin','technical_admin']::public.whp_platform_role[])
  );

-- Append-only usage ledger; unique source event prevents double-counting
-- when Meta webhooks or workers retry delivery.
CREATE TABLE IF NOT EXISTS public.whp_usage_ledger (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES public.accounts(id) ON DELETE RESTRICT,
  metric TEXT NOT NULL CHECK (length(trim(metric)) BETWEEN 1 AND 80),
  quantity BIGINT NOT NULL CHECK (quantity <> 0),
  source TEXT NOT NULL,
  source_event_id TEXT NOT NULL,
  period_start DATE NOT NULL,
  period_end DATE NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, metric, source, source_event_id),
  CHECK (period_end >= period_start)
);
CREATE INDEX IF NOT EXISTS idx_whp_usage_account_period
  ON public.whp_usage_ledger(account_id, period_start, period_end, metric);
ALTER TABLE public.whp_usage_ledger ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS whp_usage_read_owner ON public.whp_usage_ledger;
CREATE POLICY whp_usage_read_owner ON public.whp_usage_ledger
  FOR SELECT TO authenticated
  USING (
    public.is_account_member(account_id, 'owner')
    OR public.whp_is_platform_role(ARRAY['super_admin','billing_admin','technical_admin']::public.whp_platform_role[])
  );

CREATE TABLE IF NOT EXISTS public.whp_audit_logs (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id UUID REFERENCES public.accounts(id) ON DELETE SET NULL,
  actor_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  actor_scope TEXT NOT NULL CHECK (actor_scope IN ('tenant','platform','system')),
  action TEXT NOT NULL,
  target_type TEXT,
  target_id TEXT,
  request_id TEXT,
  ip_address INET,
  user_agent TEXT,
  before_data JSONB,
  after_data JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_whp_audit_account_created
  ON public.whp_audit_logs(account_id, created_at DESC);
ALTER TABLE public.whp_audit_logs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS whp_audit_read_scope ON public.whp_audit_logs;
CREATE POLICY whp_audit_read_scope ON public.whp_audit_logs
  FOR SELECT TO authenticated
  USING (
    (account_id IS NOT NULL AND public.is_account_member(account_id, 'admin'))
    OR public.whp_is_platform_role()
  );

COMMENT ON TABLE public.account_memberships IS
  'Many-to-many customer account membership. profiles.account_id remains the legacy default-account pointer during rollout.';
COMMENT ON TABLE public.whp_subscriptions IS
  'WHMCS service/subscription mirror. WHMCS is the billing system of record.';
COMMENT ON TABLE public.whp_usage_ledger IS
  'Append-only usage events; corrections are separate adjustment events.';
