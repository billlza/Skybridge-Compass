export type Fetcher = (
  input: string | URL | Request,
  init?: RequestInit,
) => Promise<Response>;

export class HTTPError extends Error {
  constructor(public readonly status: number, public readonly code: string) {
    super(code);
  }
}

export function json(
  status: number,
  value: unknown,
  headers: Record<string, string> = {},
) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { ...headers, "Content-Type": "application/json" },
  });
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export async function readObject(
  request: Request,
  limit = 65536,
): Promise<Record<string, unknown>> {
  const reader = request.body?.getReader();
  if (!reader) throw new HTTPError(400, "INVALID_JSON");
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > limit) {
        await reader.cancel();
        throw new HTTPError(413, "REQUEST_TOO_LARGE");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const body = new Uint8Array(bytes);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.length;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body));
  } catch {
    throw new HTTPError(400, "INVALID_JSON");
  }
  if (!isRecord(parsed)) throw new HTTPError(400, "INVALID_JSON_OBJECT");
  return parsed;
}

export async function upstream(
  fetcher: Fetcher,
  url: URL,
  init: RequestInit,
): Promise<Response> {
  try {
    return await fetcher(url, { ...init, signal: AbortSignal.timeout(10000) });
  } catch (error) {
    if (
      error instanceof Error &&
      ["AbortError", "TimeoutError"].includes(error.name)
    ) throw new HTTPError(504, "UPSTREAM_TIMEOUT");
    throw new HTTPError(502, "UPSTREAM_UNREACHABLE");
  }
}

export async function responseJSON(response: Response): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    throw new HTTPError(502, "INVALID_UPSTREAM_RESPONSE");
  }
}

export function errorResponse(
  error: unknown,
  headers: Record<string, string> = {},
) {
  const failure = error instanceof HTTPError
    ? error
    : new HTTPError(500, "INTERNAL_ERROR");
  return json(failure.status, { error: { code: failure.code } }, headers);
}
