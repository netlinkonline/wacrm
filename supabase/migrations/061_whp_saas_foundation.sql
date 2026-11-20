-- WHP WhatsApp SaaS foundation, additive migration 061
-- Apply only after the full WACRM migration chain on an isolated staging DB.
-- This migration does not rewrite or backfill legacy WACRM account data.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'whp_platform_role') THEN
    CREATE TYPE public.whp_platform_role AS ENUM ('super_admin','billing_admin','support_admin','technical_admin','analyst');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'whp_tenant_role') THEN
    CREATE TYPE public.whp_tenant_role AS ENUM ('owner','admin','agent','viewer');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'whp_tenant_status') THEN
    CREATE TYPE public.whp_tenant_status AS ENUM ('provisioning','trial','active','past_due','grace','suspended','terminated');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.whp_tenants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 160),
  slug TEXT NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$'),
  status public.whp_tenant_status NOT NULL DEFAULT 'provisioning',
  default_currency CHAR(3) NOT NULL DEFAULT 'INR',
  timezone TEXT NOT NULL DEFAULT 'Asia/Kolkata',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  terminated_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS public.whp_tenant_memberships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES public.whp_tenants(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.whp_tenant_role NOT NULL DEFAULT 'viewer',
  is_active BOOLEAN NOT NULL DEFAULT true,
  invited_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  joined_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id,user_id),
  UNIQUE (tenant_id,id)
);
CREATE INDEX IF NOT EXISTS idx_whp_memberships_user_active ON public.whp_tenant_memberships(user_id,is_active);
CREATE INDEX IF NOT EXISTS idx_whp_memberships_tenant_active ON public.whp_tenant_memberships(tenant_id,is_active);

CREATE TABLE IF NOT EXISTS public.whp_platform_roles (
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.whp_platform_role NOT NULL,
  granted_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_at TIMESTAMPTZ,
  PRIMARY KEY (user_id,role)
);

CREATE TABLE IF NOT EXISTS public.whp_tenant_settings (
  tenant_id UUID PRIMARY KEY REFERENCES public.whp_tenants(id) ON DELETE CASCADE,
  settings JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.whp_plans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE CHECK (code ~ '^[a-z0-9][a-z0-9_-]{1,63}$'),
  name TEXT NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  entitlements JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.whp_subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES public.whp_tenants(id) ON DELETE RESTRICT,
  plan_id UUID NOT NULL REFERENCES public.whp_plans(id) ON DELETE RESTRICT,
  status TEXT NOT NULL CHECK (status IN ('pending','trial','active','past_due','grace','suspended','cancelled','terminated')),
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
CREATE INDEX IF NOT EXISTS idx_whp_subscriptions_tenant_status ON public.whp_subscriptions(tenant_id,status);

CREATE TABLE IF NOT EXISTS public.whp_usage_ledger (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID NOT NULL REFERENCES public.whp_tenants(id) ON DELETE RESTRICT,
  metric TEXT NOT NULL CHECK (length(trim(metric)) BETWEEN 1 AND 80),
  quantity BIGINT NOT NULL CHECK (quantity <> 0),
  source TEXT NOT NULL,
  source_event_id TEXT NOT NULL,
  period_start DATE NOT NULL,
  period_end DATE NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (tenant_id,metric,source,source_event_id),
  CHECK (period_end >= period_start)
);
CREATE INDEX IF NOT EXISTS idx_whp_usage_tenant_period ON public.whp_usage_ledger(tenant_id,period_start,period_end,metric);

CREATE TABLE IF NOT EXISTS public.whp_audit_logs (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id UUID REFERENCES public.whp_tenants(id) ON DELETE SET NULL,
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
CREATE INDEX IF NOT EXISTS idx_whp_audit_tenant_created ON public.whp_audit_logs(tenant_id,created_at DESC);

CREATE OR REPLACE FUNCTION public.whp_is_tenant_member(
  p_tenant_id UUID,
  p_min_role public.whp_tenant_role DEFAULT 'viewer'
) RETURNS BOOLEAN
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.whp_tenant_memberships m
    WHERE m.tenant_id = p_tenant_id
      AND m.user_id = (SELECT auth.uid())
      AND m.is_active
      AND CASE m.role WHEN 'owner' THEN 4 WHEN 'admin' THEN 3 WHEN 'agent' THEN 2 WHEN 'viewer' THEN 1 END
        >= CASE p_min_role WHEN 'owner' THEN 4 WHEN 'admin' THEN 3 WHEN 'agent' THEN 2 WHEN 'viewer' THEN 1 END
  );
$$;

CREATE OR REPLACE FUNCTION public.whp_is_platform_admin()
RETURNS BOOLEAN
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.whp_platform_roles r
    WHERE r.user_id = (SELECT auth.uid())
      AND r.revoked_at IS NULL
      AND r.role IN ('super_admin','technical_admin')
  );
$$;

ALTER FUNCTION public.whp_is_tenant_member(UUID,public.whp_tenant_role) OWNER TO postgres;
ALTER FUNCTION public.whp_is_platform_admin() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.whp_is_tenant_member(UUID,public.whp_tenant_role) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.whp_is_platform_admin() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.whp_is_tenant_member(UUID,public.whp_tenant_role) TO authenticated;
GRANT EXECUTE ON FUNCTION public.whp_is_platform_admin() TO authenticated;

ALTER TABLE public.whp_tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.whp_tenant_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.whp_platform_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.whp_tenant_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.whp_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.whp_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.whp_usage_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.whp_audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS whp_tenants_select_member ON public.whp_tenants;
CREATE POLICY whp_tenants_select_member ON public.whp_tenants FOR SELECT TO authenticated
USING (public.whp_is_tenant_member(id,'viewer') OR public.whp_is_platform_admin());

DROP POLICY IF EXISTS whp_memberships_select_scope ON public.whp_tenant_memberships;
CREATE POLICY whp_memberships_select_scope ON public.whp_tenant_memberships FOR SELECT TO authenticated
USING (public.whp_is_tenant_member(tenant_id,'viewer') OR public.whp_is_platform_admin());

DROP POLICY IF EXISTS whp_platform_roles_select_scope ON public.whp_platform_roles;
CREATE POLICY whp_platform_roles_select_scope ON public.whp_platform_roles FOR SELECT TO authenticated
USING (user_id = (SELECT auth.uid()) OR public.whp_is_platform_admin());

DROP POLICY IF EXISTS whp_settings_select_scope ON public.whp_tenant_settings;
CREATE POLICY whp_settings_select_scope ON public.whp_tenant_settings FOR SELECT TO authenticated
USING (public.whp_is_tenant_member(tenant_id,'viewer') OR public.whp_is_platform_admin());

DROP POLICY IF EXISTS whp_plans_select_active ON public.whp_plans;
CREATE POLICY whp_plans_select_active ON public.whp_plans FOR SELECT TO authenticated
USING (is_active OR public.whp_is_platform_admin());

DROP POLICY IF EXISTS whp_subscriptions_select_scope ON public.whp_subscriptions;
CREATE POLICY whp_subscriptions_select_scope ON public.whp_subscriptions FOR SELECT TO authenticated
USING (public.whp_is_tenant_member(tenant_id,'owner') OR public.whp_is_platform_admin());

DROP POLICY IF EXISTS whp_usage_select_scope ON public.whp_usage_ledger;
CREATE POLICY whp_usage_select_scope ON public.whp_usage_ledger FOR SELECT TO authenticated
USING (public.whp_is_tenant_member(tenant_id,'owner') OR public.whp_is_platform_admin());

DROP POLICY IF EXISTS whp_audit_select_scope ON public.whp_audit_logs;
CREATE POLICY whp_audit_select_scope ON public.whp_audit_logs FOR SELECT TO authenticated
USING ((tenant_id IS NOT NULL AND public.whp_is_tenant_member(tenant_id,'admin')) OR public.whp_is_platform_admin());

-- No authenticated client write policies are intentionally created here.
-- Provisioning, membership grants, plan changes, usage and audit writes must
-- be handled by trusted server-side operations with explicit authorization.

COMMENT ON TABLE public.whp_tenants IS 'WHP SaaS organizations, separate from legacy WACRM accounts until explicit mapping is approved.';
COMMENT ON TABLE public.whp_usage_ledger IS 'Append-only usage events; corrections must be represented by adjustment events.';
COMMENT ON TABLE public.whp_subscriptions IS 'Mirrored WHMCS subscription/service state; WHMCS remains billing authority.';
