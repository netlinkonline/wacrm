import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const migrationsDir = join(process.cwd(), "supabase", "migrations");

const migrations = readdirSync(migrationsDir)
  .filter((name) => name.endsWith(".sql"))
  .sort()
  .map((name) => ({ name, sql: readFileSync(join(migrationsDir, name), "utf8") }));

const tablesWithoutDomainData = new Set([
  "profiles",
  "account_invitations",
  "member_presence",
  "pending_message_statuses",
]);

function accountScopedTables(): Set<string> {
  const tables = new Set<string>();
  const accountForeignKey = /\baccount_id\s+uuid\b[^,;]*references\s+(?:public\.)?accounts\s*\(\s*id\s*\)/i;
  const tableName = /(?:create\s+table(?:\s+if\s+not\s+exists)?|alter\s+table)\s+(?:public\.)?(\w+)/i;
  for (const { sql } of migrations) {
    for (const statement of sql.split(";")) {
      if (!accountForeignKey.test(statement)) continue;
      const match = statement.match(tableName);
      if (match) tables.add(match[1].toLowerCase());
    }
  }
  return tables;
}

function latestFunctionBody(functionName: string): string {
  const header = new RegExp(`create\\s+or\\s+replace\\s+function\\s+public\\.${functionName}\\s*\\(`, "i");
  const latest = migrations.filter(({ sql }) => header.test(sql)).at(-1);
  if (!latest) throw new Error(`${functionName} is not defined in any migration`);
  const start = latest.sql.search(header);
  const bodyStart = latest.sql.indexOf("$$", start);
  const bodyEnd = latest.sql.indexOf("$$", bodyStart + 2);
  return latest.sql.slice(bodyStart + 2, bodyEnd);
}

describe("redeem_invitation migration", () => {
  const body = latestFunctionBody("redeem_invitation");

  it("adds the invited user to the invited organization membership", () => {
    expect(body).toMatch(/insert\s+into\s+public\.account_memberships/i);
    expect(body).toMatch(/account_id,\s*user_id,\s*role,\s*status/i);
    expect(body).toMatch(/v_inv\.account_id,\s*v_user,\s*v_inv\.role,\s*'active'/i);
  });

  it("allows a user to retain memberships in multiple organizations", () => {
    expect(body).toMatch(/account_memberships[\s\S]*?where\s+account_id\s*=\s*v_inv\.account_id\s+and\s+user_id\s*=\s*v_user/i);
    expect(body).toMatch(/on\s+conflict\s*\(account_id,\s*user_id\)\s+do\s+update/i);
    expect(body).toMatch(/do\s+not\s+move\/delete\s+the\s+user's\s+existing\s+account/i);
  });

  it("does not delete or migrate the user's existing account data", () => {
    expect(body).not.toMatch(/delete\s+from\s+public\.accounts/i);
    expect(body).not.toMatch(/delete\s+from\s+public\.(contacts|tags|conversations|messages)/i);
    expect(body).not.toMatch(/update\s+public\.profiles\s+set\s+account_id/i);
  });
});

describe("member RPC migrations", () => {
  it.each(["set_member_role", "remove_account_member", "transfer_account_ownership"])(
    "%s locks the caller and target profiles in user_id order",
    (functionName) => {
      expect(latestFunctionBody(functionName)).toMatch(
        /from\s+profiles\s+where\s+user_id\s+in\s*\(\s*auth\.uid\(\),\s*p_\w+\s*\)\s+order\s+by\s+user_id\s+for\s+update/i,
      );
    },
  );
});
