import { timingSafeEqual } from "node:crypto";
import {
  errorResponse,
  type Fetcher,
  HTTPError,
  json,
  readObject,
  upstream,
} from "../_shared/http.ts";

type Configuration = {
  url?: string;
  serviceKey?: string;
  maintenanceToken?: string;
};
type Operation = {
  name: string;
  table: string;
  filters: Record<string, string>;
  method: string;
  body?: Record<string, unknown>;
};

export async function handleMaintenance(
  request: Request,
  config: Configuration,
  fetcher: Fetcher = fetch,
): Promise<Response> {
  if (request.method !== "POST") {
    return json(405, { error: { code: "METHOD_NOT_ALLOWED" } });
  }
  try {
    const secret = config.maintenanceToken;
    if (!secret || !/^[0-9a-f]{64}$/.test(secret)) {
      throw new HTTPError(503, "SERVER_MISCONFIGURED");
    }
    const token = request.headers.get("Authorization")?.match(
      /^Bearer ([0-9a-f]{64})$/,
    )?.[1];
    if (
      !token ||
      !timingSafeEqual(
        new TextEncoder().encode(token),
        new TextEncoder().encode(secret),
      )
    ) {
      throw new HTTPError(401, "UNAUTHORIZED");
    }
    if (!config.url || !config.serviceKey) {
      throw new HTTPError(503, "SERVER_MISCONFIGURED");
    }
    const input = await readObject(request, 4096);
    if (input.dry_run !== undefined && typeof input.dry_run !== "boolean") {
      throw new HTTPError(400, "INVALID_DRY_RUN");
    }
    const dryRun = input.dry_run === true;
    const now = new Date();
    const before = (milliseconds: number) =>
      new Date(now.getTime() - milliseconds).toISOString();
    const operations: Operation[] = [
      {
        name: "offline_devices_updated",
        table: "devices",
        method: "PATCH",
        filters: { is_online: "eq.true", last_seen_at: `lt.${before(300000)}` },
        body: { is_online: false, updated_at: now.toISOString() },
      },
      {
        name: "expired_connections_cleaned",
        table: "device_connections",
        method: "DELETE",
        filters: {
          connection_status: "eq.disconnected",
          disconnected_at: `lt.${before(7 * 86400000)}`,
        },
      },
      {
        name: "old_messages_cleaned",
        table: "real_time_messages",
        method: "DELETE",
        filters: { is_read: "eq.true", read_at: `lt.${before(30 * 86400000)}` },
      },
      {
        name: "old_logs_cleaned",
        table: "system_logs",
        method: "DELETE",
        filters: {
          log_level: "neq.ERROR",
          created_at: `lt.${before(30 * 86400000)}`,
        },
      },
      {
        name: "expired_api_keys_disabled",
        table: "api_keys",
        method: "PATCH",
        filters: {
          expires_at: `lt.${now.toISOString()}`,
          is_active: "eq.true",
        },
        body: { is_active: false },
      },
      {
        name: "expired_permissions_disabled",
        table: "device_permissions",
        method: "PATCH",
        filters: {
          expires_at: `lt.${now.toISOString()}`,
          is_active: "eq.true",
        },
        body: { is_active: false },
      },
    ];
    const headers = {
      Authorization: `Bearer ${config.serviceKey}`,
      apikey: config.serviceKey,
      "Content-Type": "application/json",
      Prefer: "return=minimal",
    };
    const completed: string[] = [];
    for (const operation of operations) {
      const url = new URL(`/rest/v1/${operation.table}`, config.url);
      url.search = new URLSearchParams(
        dryRun
          ? { ...operation.filters, select: "id", limit: "0" }
          : operation.filters,
      ).toString();
      const response = await upstream(fetcher, url, {
        method: dryRun ? "GET" : operation.method,
        headers,
        body: !dryRun && operation.body
          ? JSON.stringify(operation.body)
          : undefined,
      });
      await response.body?.cancel();
      if (!response.ok) {
        return json(502, {
          error: {
            code: "MAINTENANCE_STEP_FAILED",
            step: operation.name,
            upstream_status: response.status,
          },
          completed,
          dry_run: dryRun,
        });
      }
      completed.push(operation.name);
    }
    if (!dryRun) {
      const log = await upstream(
        fetcher,
        new URL("/rest/v1/system_logs", config.url),
        {
          method: "POST",
          headers,
          body: JSON.stringify({
            log_level: "INFO",
            log_category: "SCHEDULED_MAINTENANCE",
            log_message: "定时维护任务执行完成",
            log_data: { completed, execution_time: now.toISOString() },
            created_at: now.toISOString(),
          }),
        },
      );
      await log.body?.cancel();
      if (!log.ok) {
        return json(502, {
          error: {
            code: "MAINTENANCE_LOG_FAILED",
            upstream_status: log.status,
          },
          completed,
        });
      }
    }
    return json(200, {
      data: { dry_run: dryRun, completed, execution_time: now.toISOString() },
    });
  } catch (error) {
    return errorResponse(error);
  }
}
