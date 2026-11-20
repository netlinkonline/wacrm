import { createClient } from "@/lib/supabase/server";
import { UnauthorizedError, ForbiddenError } from "@/lib/auth/account";

export type PlatformRole =
  | "super_admin"
  | "billing_admin"
  | "support_admin"
  | "technical_admin"
  | "analyst";

export interface PlatformContext {
  userId: string;
  roles: PlatformRole[];
}

const PLATFORM_ROLES: readonly PlatformRole[] = [
  "super_admin",
  "billing_admin",
  "support_admin",
  "technical_admin",
  "analyst",
];

export async function requirePlatformRole(
  allowed: readonly PlatformRole[] = ["super_admin"],
): Promise<PlatformContext> {
  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) throw new UnauthorizedError();

  const { data, error } = await supabase
    .from("whp_platform_roles")
    .select("role")
    .eq("user_id", user.id)
    .is("revoked_at", null);

  if (error) {
    console.error("[requirePlatformRole] role lookup failed:", error);
    throw new ForbiddenError("Could not verify platform access");
  }

  const roles = (data ?? [])
    .map((row) => row.role)
    .filter((role): role is PlatformRole =>
      typeof role === "string" && (PLATFORM_ROLES as readonly string[]).includes(role),
    );

  if (!roles.some((role) => allowed.includes(role))) {
    throw new ForbiddenError("Platform administrator access required");
  }

  return { userId: user.id, roles };
}
