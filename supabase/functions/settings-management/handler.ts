import {
  errorResponse,
  type Fetcher,
  HTTPError,
  isRecord,
  json,
  readObject,
  responseJSON,
  upstream,
} from "../_shared/http.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
  "Access-Control-Max-Age": "86400",
};
const defaults = {
  theme: "dark",
  language: "zh-CN",
  interface_density: "standard",
  email_notifications: true,
  system_notifications: true,
  security_notifications: true,
  profile_visibility: "private",
  data_usage_analytics: false,
};

export async function handleSettings(
  request: Request,
  config: { url?: string; anonKey?: string },
  fetcher: Fetcher = fetch,
): Promise<Response> {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: cors });
  }
  if (!["GET", "POST"].includes(request.method)) {
    return json(405, { error: { code: "METHOD_NOT_ALLOWED" } }, cors);
  }
  const authorization = request.headers.get("Authorization");
  if (!authorization || !/^Bearer \S+$/i.test(authorization)) {
    return json(401, { error: { code: "UNAUTHORIZED" } }, cors);
  }
  try {
    if (!config.url || !config.anonKey) {
      throw new HTTPError(503, "SERVER_MISCONFIGURED");
    }
    // Database requests retain the verified caller's token. No service-role
    // client or request-supplied identity can bypass the ownership policy.
    const headers = {
      Authorization: authorization,
      apikey: config.anonKey,
      "Content-Type": "application/json",
    };
    const auth = await upstream(fetcher, new URL("/auth/v1/user", config.url), {
      headers,
    });
    if (auth.status === 401 || auth.status === 403) {
      await auth.body?.cancel();
      throw new HTTPError(401, "UNAUTHORIZED");
    }
    if (!auth.ok) {
      await auth.body?.cancel();
      throw new HTTPError(502, "AUTH_UNAVAILABLE");
    }
    const user = await responseJSON(auth);
    if (
      !isRecord(user) || typeof user.id !== "string" ||
      !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(user.id)
    ) throw new HTTPError(502, "INVALID_AUTH_RESPONSE");
    const userId = user.id;
    async function database(
      table: string,
      parameters: Record<string, string>,
      method = "GET",
      body?: unknown,
    ) {
      const url = new URL(`/rest/v1/${table}`, config.url);
      url.search = new URLSearchParams(parameters).toString();
      const response = await upstream(fetcher, url, {
        method,
        headers: {
          ...headers,
          Prefer: method === "POST"
            ? "resolution=merge-duplicates,return=minimal"
            : "return=minimal",
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      if (!response.ok) {
        await response.body?.cancel();
        throw new HTTPError(502, "DATABASE_REQUEST_FAILED");
      }
      if (method !== "GET") {
        await response.body?.cancel();
        return null;
      }
      const rows = await responseJSON(response);
      if (!Array.isArray(rows) || !rows.every(isRecord)) {
        throw new HTTPError(502, "INVALID_DATABASE_RESPONSE");
      }
      return rows;
    }
    if (request.method === "GET") {
      const rows = await database("user_settings", {
        user_id: `eq.${userId}`,
        select: "setting_key,setting_value,setting_type",
      });
      if (rows === null) throw new HTTPError(502, "INVALID_DATABASE_RESPONSE");
      const settings: Record<string, unknown> = Object.create(null);
      for (const row of rows) {
        if (
          typeof row.setting_key !== "string" ||
          typeof row.setting_value !== "string"
        ) throw new HTTPError(502, "INVALID_SETTING");
        let value: unknown = row.setting_value;
        if (["json", "boolean"].includes(String(row.setting_type))) {
          try {
            value = JSON.parse(row.setting_value);
          } catch {
            throw new HTTPError(502, "CORRUPT_SETTING");
          }
        }
        settings[row.setting_key] = value;
      }
      return json(200, { data: rows.length === 0 ? defaults : settings }, cors);
    }
    const body = await readObject(request);
    if (body.action === "update_settings") {
      if (!isRecord(body.settings) || Object.keys(body.settings).length > 100) {
        throw new HTTPError(400, "INVALID_SETTINGS");
      }
      const entries = Object.entries(body.settings);
      if (
        entries.length === 0 ||
        entries.some(([key]) => key.length === 0 || key.length > 100)
      ) throw new HTTPError(400, "INVALID_SETTINGS");
      const rows = entries.map(([key, value]) => ({
        user_id: userId,
        setting_key: key,
        setting_value: typeof value === "string"
          ? value
          : JSON.stringify(value),
        setting_type: typeof value === "boolean"
          ? "boolean"
          : typeof value === "object"
          ? "json"
          : "string",
        updated_at: new Date().toISOString(),
      }));
      await database(
        "user_settings",
        { on_conflict: "user_id,setting_key" },
        "POST",
        rows,
      );
      return json(200, { success: true, message: "设置更新成功" }, cors);
    }
    if (body.action === "reset_to_default") {
      await database("user_settings", { user_id: `eq.${userId}` }, "DELETE");
      return json(200, { success: true, message: "设置已重置为默认值" }, cors);
    }
    if (body.action === "get_account_info") {
      const rows = await database("user_profiles", {
        id: `eq.${userId}`,
        select: "*",
        limit: "1",
      });
      if (rows === null) throw new HTTPError(502, "INVALID_DATABASE_RESPONSE");
      return json(200, {
        data: {
          user_id: userId,
          email: user.email ?? null,
          created_at: user.created_at ?? null,
          profile: rows[0] ?? null,
        },
      }, cors);
    }
    throw new HTTPError(400, "INVALID_ACTION");
  } catch (error) {
    return errorResponse(error, cors);
  }
}
