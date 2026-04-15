const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, webhook-id, webhook-signature, webhook-timestamp",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const upstreamTimeoutMs = Number(
  Deno.env.get("SMS_HOOK_PROXY_TIMEOUT_MS") ?? "10000",
);

function responseWith(
  status: number,
  body: string,
  contentType = "application/json",
) {
  return new Response(body, {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": contentType,
    },
  });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return responseWith(405, JSON.stringify({ error: "method_not_allowed" }));
  }

  const upstreamURL = Deno.env.get("SMS_HOOK_PROXY_UPSTREAM_URL");
  if (!upstreamURL) {
    return responseWith(
      500,
      JSON.stringify({
        error: "server_misconfigured",
        details: "Missing SMS_HOOK_PROXY_UPSTREAM_URL",
      }),
    );
  }

  const rawBody = await request.text();
  let upstreamResponse: Response;
  try {
    upstreamResponse = await fetch(upstreamURL, {
      method: "POST",
      headers: {
        "Content-Type": request.headers.get("Content-Type") ??
          "application/json",
        "webhook-id": request.headers.get("webhook-id") ?? "",
        "webhook-signature": request.headers.get("webhook-signature") ?? "",
        "webhook-timestamp": request.headers.get("webhook-timestamp") ?? "",
      },
      body: rawBody,
      signal: AbortSignal.timeout(upstreamTimeoutMs),
    });
  } catch (error) {
    const isTimeout = error instanceof Error &&
      (error.name === "TimeoutError" || error.name === "AbortError");
    return responseWith(
      isTimeout ? 504 : 502,
      JSON.stringify({
        error: isTimeout ? "upstream_timeout" : "upstream_unreachable",
      }),
    );
  }

  const upstreamBody = await upstreamResponse.text();
  const upstreamContentType = upstreamResponse.headers.get("Content-Type") ??
    "application/json";

  return responseWith(
    upstreamResponse.status,
    upstreamBody,
    upstreamContentType,
  );
});
