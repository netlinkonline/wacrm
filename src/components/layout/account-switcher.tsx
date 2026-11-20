"use client";

import { useCallback, useEffect, useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { ChevronsUpDown, Plus, UsersRound } from "lucide-react";

import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

type AccountOption = {
  id: string;
  name: string;
  role: "owner" | "admin" | "agent" | "viewer";
  active: boolean;
};

export function AccountSwitcher() {
  const router = useRouter();
  const [accounts, setAccounts] = useState<AccountOption[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [switching, setSwitching] = useState(false);
  const [createOpen, setCreateOpen] = useState(false);
  const [newName, setNewName] = useState("");
  const [creating, setCreating] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);

  const loadAccounts = useCallback(async () => {
    try {
      const response = await fetch("/api/account/active", { cache: "no-store" });
      if (!response.ok) return;
      const payload = (await response.json()) as { accounts?: AccountOption[] };
      const rows = payload.accounts ?? [];
      setAccounts(rows);
      setActiveId(rows.find((row) => row.active)?.id ?? null);
    } catch (error) {
      console.error("[AccountSwitcher] could not load organizations:", error);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void loadAccounts();
  }, [loadAccounts]);

  async function selectAccount(accountId: string) {
    if (accountId === activeId || switching) return;
    setSwitching(true);
    try {
      const response = await fetch("/api/account/active", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ accountId }),
      });
      if (!response.ok) {
        const payload = (await response.json().catch(() => ({}))) as { error?: string };
        throw new Error(payload.error ?? "Could not switch organization");
      }
      setActiveId(accountId);
      await loadAccounts();
      router.refresh();
    } catch (error) {
      console.error("[AccountSwitcher] switch failed:", error);
    } finally {
      setSwitching(false);
    }
  }

  async function createAccount(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (creating) return;
    setCreating(true);
    setCreateError(null);
    try {
      const response = await fetch("/api/account/organizations", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: newName }),
      });
      const payload = (await response.json().catch(() => ({}))) as {
        accountId?: string;
        error?: string;
      };
      if (!response.ok || !payload.accountId) {
        throw new Error(payload.error ?? "Could not create organization");
      }
      setCreateOpen(false);
      setNewName("");
      setActiveId(payload.accountId);
      await loadAccounts();
      router.refresh();
    } catch (error) {
      setCreateError(error instanceof Error ? error.message : "Could not create organization");
    } finally {
      setCreating(false);
    }
  }

  if (loading || accounts.length === 0) return null;

  const active = accounts.find((account) => account.id === activeId) ?? accounts[0];

  return (
    <div className="border-b border-border px-3 py-2">
      <DropdownMenu>
        <DropdownMenuTrigger
          disabled={switching}
          className="flex w-full items-center gap-2 rounded-lg border border-border bg-background px-3 py-2 text-left transition-colors hover:bg-muted disabled:opacity-60"
          aria-label="Switch organization"
        >
          <UsersRound className="size-4 shrink-0 text-muted-foreground" />
          <span className="min-w-0 flex-1">
            <span className="block truncate text-xs font-medium text-foreground">
              {active.name}
            </span>
            <span className="block text-[10px] capitalize text-muted-foreground">
              {switching ? "Switching…" : active.role}
            </span>
          </span>
          <ChevronsUpDown className="size-3.5 shrink-0 text-muted-foreground" />
        </DropdownMenuTrigger>
        <DropdownMenuContent align="start" side="right" className="min-w-60">
          <div className="px-2 py-1.5 text-xs font-medium text-muted-foreground">
            Your organizations
          </div>
          {accounts.map((account) => (
            <DropdownMenuItem
              key={account.id}
              onClick={() => void selectAccount(account.id)}
              className="flex items-center justify-between gap-3"
            >
              <span className="min-w-0 truncate">{account.name}</span>
              <span className="shrink-0 text-[10px] capitalize text-muted-foreground">
                {account.role}{account.id === activeId ? " · Active" : ""}
              </span>
            </DropdownMenuItem>
          ))}
          <DropdownMenuSeparator />
          <DropdownMenuItem onClick={() => setCreateOpen(true)}>
            <Plus className="size-4" />
            Create organization
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
      {createOpen && (
        <div className="fixed inset-0 z-[100] flex items-center justify-center bg-black/50 p-4" onMouseDown={(event) => {
          if (event.target === event.currentTarget && !creating) setCreateOpen(false);
        }}>
          <form
            role="dialog"
            aria-modal="true"
            aria-labelledby="create-organization-title"
            onSubmit={createAccount}
            className="w-full max-w-md space-y-4 rounded-xl border border-border bg-card p-5 shadow-xl"
          >
            <div>
              <h2 id="create-organization-title" className="text-base font-semibold text-foreground">Create organization</h2>
              <p className="mt-1 text-sm text-muted-foreground">Create a separate workspace for another business or team.</p>
            </div>
            <label className="block space-y-1.5 text-sm font-medium text-foreground">
              Organization name
              <input
                autoFocus
                required
                minLength={2}
                maxLength={120}
                value={newName}
                onChange={(event) => setNewName(event.target.value)}
                placeholder="e.g. Example Company"
                className="h-10 w-full rounded-lg border border-border bg-background px-3 text-sm outline-none focus:border-primary"
              />
            </label>
            {createError && <p role="alert" className="text-sm text-destructive">{createError}</p>}
            <div className="flex justify-end gap-2">
              <button type="button" disabled={creating} onClick={() => setCreateOpen(false)} className="rounded-lg border border-border px-3 py-2 text-sm text-foreground hover:bg-muted disabled:opacity-50">Cancel</button>
              <button type="submit" disabled={creating || newName.trim().length < 2} className="rounded-lg bg-primary px-3 py-2 text-sm font-medium text-primary-foreground disabled:opacity-50">{creating ? "Creating…" : "Create organization"}</button>
            </div>
          </form>
        </div>
      )}
    </div>
  );
}
