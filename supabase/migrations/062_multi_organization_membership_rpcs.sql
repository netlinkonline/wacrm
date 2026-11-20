-- WHP multi-organization membership operations
-- All functions are SECURITY DEFINER with a fixed search_path. The
-- authenticated caller is revalidated against account_memberships.
-- Legacy WACRM RPCs remain available during UI/API migration.

CREATE OR REPLACE FUNCTION public.create_account_invitation(
  p_account_id UUID,
  p_token_hash TEXT,
  p_role public.account_role_enum,
  p_expires_at TIMESTAMPTZ,
  p_label TEXT DEFAULT NULL
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;
  IF p_role = 'owner' OR p_expires_at <= now() OR p_expires_at > now() + interval '30 days' THEN
    RAISE EXCEPTION 'Invalid invitation role or expiry' USING ERRCODE = '22023';
  END IF;
  IF NOT public.is_account_member(p_account_id, 'admin') THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.account_invitations
    (account_id, token_hash, role, created_by_user_id, label, expires_at)
  VALUES
    (p_account_id, p_token_hash, p_role, auth.uid(), p_label, p_expires_at)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.redeem_invitation(
  p_token_hash TEXT
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user UUID := auth.uid();
  v_inv public.account_invitations%ROWTYPE;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_inv
  FROM public.account_invitations
  WHERE token_hash = p_token_hash
  FOR UPDATE;

  IF NOT FOUND OR v_inv.accepted_at IS NOT NULL OR v_inv.expires_at <= now() THEN
    RAISE EXCEPTION 'Invitation is invalid, expired or already redeemed' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.account_memberships
    WHERE account_id = v_inv.account_id AND user_id = v_user AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'You are already a member of this organization' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.account_memberships
    (account_id, user_id, role, status, invited_by_user_id, joined_at)
  VALUES
    (v_inv.account_id, v_user, v_inv.role, 'active', v_inv.created_by_user_id, now())
  ON CONFLICT (account_id, user_id) DO UPDATE
    SET role = EXCLUDED.role, status = 'active', joined_at = now();

  UPDATE public.account_invitations
  SET accepted_at = now(), accepted_by_user_id = v_user
  WHERE id = v_inv.id;

  -- Do not move/delete the user's existing account or its data. The
  -- account selector chooses which active membership to use.
  RETURN v_inv.account_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_account_member_role(
  p_account_id UUID,
  p_user_id UUID,
  p_new_role public.account_role_enum
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_target_role public.account_role_enum;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT public.is_account_member(p_account_id, 'admin') THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
  END IF;
  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Cannot change your own role' USING ERRCODE = '22023';
  END IF;

  SELECT role INTO v_target_role
  FROM public.account_memberships
  WHERE account_id = p_account_id AND user_id = p_user_id AND status = 'active'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active organization member not found' USING ERRCODE = '22023';
  END IF;
  IF v_target_role = 'owner' OR p_new_role = 'owner' THEN
    RAISE EXCEPTION 'Ownership changes require the ownership transfer operation' USING ERRCODE = '22023';
  END IF;

  UPDATE public.account_memberships
  SET role = p_new_role, updated_at = now()
  WHERE account_id = p_account_id AND user_id = p_user_id;

  -- Keep the old profile pointer in sync only when this is the user's
  -- legacy/default account. Other memberships have their own role.
  UPDATE public.profiles
  SET account_role = p_new_role
  WHERE user_id = p_user_id AND account_id = p_account_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.remove_account_membership(
  p_account_id UUID,
  p_user_id UUID
) RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_target_role public.account_role_enum;
  v_default_account UUID;
  v_new_account UUID;
  v_new_role public.account_role_enum;
  v_name TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;
  IF NOT public.is_account_member(p_account_id, 'admin') THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
  END IF;
  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Use the leave-organization operation to leave yourself' USING ERRCODE = '22023';
  END IF;

  SELECT role INTO v_target_role
  FROM public.account_memberships
  WHERE account_id = p_account_id AND user_id = p_user_id AND status = 'active'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Active organization member not found' USING ERRCODE = '22023';
  END IF;
  IF v_target_role = 'owner' THEN
    RAISE EXCEPTION 'Transfer ownership before removing the owner' USING ERRCODE = '22023';
  END IF;

  DELETE FROM public.account_memberships
  WHERE account_id = p_account_id AND user_id = p_user_id;

  SELECT account_id INTO v_default_account
  FROM public.profiles WHERE user_id = p_user_id FOR UPDATE;

  IF v_default_account = p_account_id THEN
    SELECT m.account_id, m.role
    INTO v_new_account, v_new_role
    FROM public.account_memberships m
    WHERE m.user_id = p_user_id AND m.status = 'active'
    ORDER BY (m.role = 'owner') DESC, m.created_at ASC
    LIMIT 1;

    IF v_new_account IS NULL THEN
      SELECT COALESCE(NULLIF(full_name, ''), email, 'My account')
      INTO v_name FROM public.profiles WHERE user_id = p_user_id;
      INSERT INTO public.accounts(name, owner_user_id)
      VALUES (COALESCE(v_name, 'My account'), p_user_id)
      RETURNING id INTO v_new_account;
      INSERT INTO public.account_memberships(account_id,user_id,role,status,joined_at)
      VALUES (v_new_account,p_user_id,'owner','active',now());
      v_new_role := 'owner';
    END IF;

    UPDATE public.profiles
    SET account_id = v_new_account, account_role = v_new_role
    WHERE user_id = p_user_id;
  ELSE
    v_new_account := v_default_account;
  END IF;

  RETURN v_new_account;
END;
$$;

CREATE OR REPLACE FUNCTION public.transfer_account_membership_ownership(
  p_account_id UUID,
  p_new_owner_user_id UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_caller_role public.account_role_enum;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;

  SELECT role INTO v_caller_role
  FROM public.account_memberships
  WHERE account_id = p_account_id AND user_id = auth.uid() AND status = 'active'
  FOR UPDATE;

  IF v_caller_role IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'Only the organization owner can transfer ownership' USING ERRCODE = '42501';
  END IF;
  IF p_new_owner_user_id = auth.uid() THEN
    RAISE EXCEPTION 'You are already the owner' USING ERRCODE = '22023';
  END IF;
  PERFORM 1
  FROM public.account_memberships
  WHERE account_id = p_account_id
    AND user_id = p_new_owner_user_id
    AND status = 'active'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'New owner must be an active organization member' USING ERRCODE = '22023';
  END IF;

  UPDATE public.account_memberships
  SET role = 'admin', updated_at = now()
  WHERE account_id = p_account_id AND user_id = auth.uid();

  UPDATE public.account_memberships
  SET role = 'owner', updated_at = now()
  WHERE account_id = p_account_id AND user_id = p_new_owner_user_id;

  UPDATE public.accounts SET owner_user_id = p_new_owner_user_id WHERE id = p_account_id;

  UPDATE public.profiles SET account_role = 'admin'
  WHERE user_id = auth.uid() AND account_id = p_account_id;
  UPDATE public.profiles SET account_role = 'owner'
  WHERE user_id = p_new_owner_user_id AND account_id = p_account_id;
END;
$$;

ALTER FUNCTION public.create_account_invitation(UUID,TEXT,public.account_role_enum,TIMESTAMPTZ,TEXT) OWNER TO postgres;
ALTER FUNCTION public.redeem_invitation(TEXT) OWNER TO postgres;
ALTER FUNCTION public.set_account_member_role(UUID,UUID,public.account_role_enum) OWNER TO postgres;
ALTER FUNCTION public.remove_account_membership(UUID,UUID) OWNER TO postgres;
ALTER FUNCTION public.transfer_account_membership_ownership(UUID,UUID) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.create_account_invitation(UUID,TEXT,public.account_role_enum,TIMESTAMPTZ,TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.redeem_invitation(TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_account_member_role(UUID,UUID,public.account_role_enum) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.remove_account_membership(UUID,UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.transfer_account_membership_ownership(UUID,UUID) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.create_account_invitation(UUID,TEXT,public.account_role_enum,TIMESTAMPTZ,TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.redeem_invitation(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_account_member_role(UUID,UUID,public.account_role_enum) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_account_membership(UUID,UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transfer_account_membership_ownership(UUID,UUID) TO authenticated;
