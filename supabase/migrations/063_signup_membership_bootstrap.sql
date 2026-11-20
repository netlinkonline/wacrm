-- Ensure every new WACRM signup receives an initial membership row.
-- Migration 061 changed is_account_member() to read account_memberships,
-- so the account/profile bootstrap trigger must populate that table.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_full_name TEXT;
  v_account_id UUID;
BEGIN
  v_full_name := COALESCE(NEW.raw_user_meta_data->>'full_name', '');

  INSERT INTO public.accounts (name, owner_user_id)
  VALUES (COALESCE(NULLIF(v_full_name, ''), NEW.email, 'My account'), NEW.id)
  RETURNING id INTO v_account_id;

  INSERT INTO public.profiles (user_id, full_name, email, account_id, account_role)
  VALUES (NEW.id, v_full_name, NEW.email, v_account_id, 'owner');

  INSERT INTO public.account_memberships
    (account_id, user_id, role, status, joined_at)
  VALUES
    (v_account_id, NEW.id, 'owner', 'active', now());

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Do not swallow bootstrap errors. A profile without its membership
  -- would be unable to access tenant RLS after migration 061.
  RAISE;
END;
$$;

ALTER FUNCTION public.handle_new_user() OWNER TO postgres;
