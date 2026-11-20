// ============================================================
// GET /api/account/members
//
// Lists every member of the caller's account. Any member can call
// it (the Members tab is shown to admins+, but agents/viewers see
// a read-only roster too).
//
// Field visibility
//   Sensitive fields (email) are returned only when the caller is
//   admin+. Agents and viewers see name + avatar + role + joined
//   date only. This mirrors the design decision from the planning
//   phase: "agent/viewer sees names only".
// ============================================================

import { NextResponse } from "next/server";

import { getCurrentAccount, toErrorResponse } from "@/lib/auth/account";
import { canManageMembers, isAccountRole } from "@/lib/auth/roles";
import type { AccountMember } from "@/types";
import { getT } from "@/lib/i18n/translate";

const t = getT("Api");

export async function GET() {
  try {
    const ctx = await getCurrentAccount();

    // RLS on profiles allows reading any row whose account matches
    // the caller's, so this query is naturally account-scoped.
    const { data: memberships, error: membershipError } = await ctx.supabase
      .from("account_memberships")
      .select("user_id, role, joined_at, created_at")
      .eq("account_id", ctx.accountId)
      .eq("status", "active")
      .order("created_at", { ascending: true });

    if (membershipError) {
      console.error("[GET /api/account/members] membership fetch error:", membershipError);
      return NextResponse.json(
        { error: t('account.members.loadFailed') },
        { status: 500 },
      );
    }

    const memberIds = (memberships ?? []).map((row) => row.user_id);
    const { data: profiles, error: profilesError } = memberIds.length
      ? await ctx.supabase
          .from("profiles")
          .select("user_id, full_name, email, avatar_url, created_at")
          .in("user_id", memberIds)
      : { data: [], error: null };

    if (profilesError) {
      console.error("[GET /api/account/members] profile fetch error:", profilesError);
      return NextResponse.json(
        { error: t('account.members.loadFailed') },
        { status: 500 },
      );
    }

    const profileById = new Map((profiles ?? []).map((profile) => [profile.user_id, profile]));

    const canSeeEmails = canManageMembers(ctx.role);

    const members: AccountMember[] = (memberships ?? []).flatMap((membership) => {
      const profile = profileById.get(membership.user_id);
      if (!profile || !isAccountRole(membership.role)) return [];
      return [{
        user_id: membership.user_id,
        full_name: profile.full_name ?? "",
        email: canSeeEmails ? profile.email : null,
        avatar_url: profile.avatar_url,
        role: membership.role,
        joined_at: membership.joined_at ?? membership.created_at,
      }];
    });

    return NextResponse.json({ members });
  } catch (err) {
    return toErrorResponse(err);
  }
}
