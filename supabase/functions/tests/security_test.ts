import { handleSettings } from "../settings-management/handler.ts";
import { handleMaintenance } from "../scheduled-maintenance/handler.ts";
import type { Fetcher } from "../_shared/http.ts";

function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
const userId = "11111111-1111-4111-8111-111111111111";
const userConfig = {
  url: "https://project.example.invalid",
  anonKey: "public-test-key",
};
const maintenanceConfig = {
  ...userConfig,
  serviceKey: "server-test-key",
  maintenanceToken: "a".repeat(64),
};
const response = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status });
const request = (body: unknown, token = "user-token") =>
  new Request("https://example.invalid/settings?nebula_user_id=nebula_victim", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });

Deno.test("a claimed nebula identity cannot bypass failed authentication", async () => {
  let calls = 0;
  const fetcher: Fetcher = () => {
    calls++;
    return Promise.resolve(response({ error: "invalid" }, 401));
  };
  const result = await handleSettings(
    request({ action: "reset_to_default", nebula_user_id: "nebula_victim" }),
    userConfig,
    fetcher,
  );
  assert(
    result.status === 401 && calls === 1,
    "unverified caller reached the database",
  );
});

Deno.test("Auth outage is explicit and does not become empty settings", async () => {
  const result = await handleSettings(
    request({ action: "get_account_info" }),
    userConfig,
    () => Promise.resolve(response({}, 503)),
  );
  assert(result.status === 502, "Auth outage returned success");
});

Deno.test("settings upsert uses verified UUID and user token in one transaction", async () => {
  let calls = 0;
  const fetcher: Fetcher = async (input, init) => {
    calls++;
    if (calls === 1) {
      return response({ id: userId, email: "test@example.invalid" });
    }
    const url = new URL(String(input));
    assert(
      url.searchParams.get("on_conflict") === "user_id,setting_key",
      "upsert key missing",
    );
    assert(
      new Headers(init?.headers).get("Authorization") === "Bearer user-token",
      "caller token was replaced",
    );
    assert(
      new Headers(init?.headers).get("apikey") === "public-test-key",
      "privileged client used",
    );
    const rows = JSON.parse(String(init?.body));
    assert(
      rows.length === 2 &&
        rows.every((row: { user_id: string }) => row.user_id === userId),
      "unverified owner entered the write",
    );
    return new Response(null, { status: 204 });
  };
  const result = await handleSettings(
    request({
      action: "update_settings",
      user_id: "victim",
      settings: { theme: "dark", enabled: true },
    }),
    userConfig,
    fetcher,
  );
  assert(result.status === 200 && calls === 2, "settings batch was not atomic");
});

Deno.test("database errors and corrupt stored settings fail explicitly", async () => {
  for (
    const backend of [
      response({}, 500),
      response([{
        setting_key: "bad",
        setting_type: "json",
        setting_value: "invalid-json",
      }]),
    ]
  ) {
    let calls = 0;
    const fetcher: Fetcher = () =>
      Promise.resolve(++calls === 1 ? response({ id: userId }) : backend);
    const req = new Request("https://example.invalid/settings", {
      headers: { Authorization: "Bearer user-token" },
    });
    const result = await handleSettings(req, userConfig, fetcher);
    assert(result.status === 502, "database failure became a default value");
  }
});

Deno.test("empty settings is a legitimate default state", async () => {
  let calls = 0;
  const fetcher: Fetcher = () =>
    Promise.resolve(++calls === 1 ? response({ id: userId }) : response([]));
  const req = new Request("https://example.invalid/settings", {
    headers: { Authorization: "Bearer user-token" },
  });
  const result = await handleSettings(req, userConfig, fetcher);
  assert(
    result.status === 200 && (await result.json()).data.theme === "dark",
    "empty state lost its defined defaults",
  );
});

Deno.test("oversized settings request is rejected before a database write", async () => {
  let calls = 0;
  const fetcher: Fetcher = () => {
    calls++;
    return Promise.resolve(response({ id: userId }));
  };
  const result = await handleSettings(
    request({
      action: "update_settings",
      settings: { content: "x".repeat(65536) },
    }),
    userConfig,
    fetcher,
  );
  assert(
    result.status === 413 && calls === 1,
    "oversized body reached the database",
  );
});

Deno.test("maintenance rejects missing and incorrect credentials before any operation", async () => {
  for (const token of ["", "b".repeat(64), "user-jwt"]) {
    let calls = 0;
    const fetcher: Fetcher = () => {
      calls++;
      return Promise.resolve(new Response(null, { status: 204 }));
    };
    const result = await handleMaintenance(
      request({}, token),
      maintenanceConfig,
      fetcher,
    );
    assert(
      result.status === 401 && calls === 0,
      "unauthorized maintenance reached privileged operations",
    );
  }
});

Deno.test("authenticated maintenance dry-run performs only empty reads", async () => {
  let calls = 0;
  const fetcher: Fetcher = (input, init) => {
    calls++;
    assert(
      init?.method === "GET" &&
        new URL(String(input)).searchParams.get("limit") === "0",
      "dry-run caused a mutation",
    );
    return Promise.resolve(response([]));
  };
  const result = await handleMaintenance(
    request({ dry_run: true }, maintenanceConfig.maintenanceToken),
    maintenanceConfig,
    fetcher,
  );
  assert(
    result.status === 200 && calls === 6,
    "dry-run did not verify all six operations",
  );
});

Deno.test("maintenance stops and reports a failed step instead of returning success", async () => {
  let calls = 0;
  const fetcher: Fetcher = () =>
    Promise.resolve(
      ++calls === 1 ? new Response(null, { status: 204 }) : response({}, 503),
    );
  const result = await handleMaintenance(
    request({}, maintenanceConfig.maintenanceToken),
    maintenanceConfig,
    fetcher,
  );
  const body = await result.json();
  assert(
    result.status === 502 && calls === 2 && body.completed.length === 1,
    "partial failure was hidden",
  );
});

Deno.test("upstream timeouts remain failures", async () => {
  const fetcher: Fetcher = () =>
    Promise.reject(new DOMException("deadline", "TimeoutError"));
  const result = await handleSettings(
    request({ action: "get_account_info" }),
    userConfig,
    fetcher,
  );
  assert(result.status === 504, "timeout was hidden");
});
