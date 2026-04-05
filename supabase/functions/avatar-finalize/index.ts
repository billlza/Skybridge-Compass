import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type FinalizePayload = {
  storage_path: string;
  mime_type?: string | null;
  file_size?: number | null;
  width?: number | null;
  height?: number | null;
  crop_data?: Record<string, unknown> | null;
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}

function normalizeStoragePath(raw: string): string {
  return raw
    .split("/")
    .map((segment) => segment.trim())
    .filter(Boolean)
    .join("/");
}

function buildCanonicalAvatarUrl(supabaseUrl: string, storagePath: string): string {
  const baseURL = supabaseUrl.endsWith("/") ? supabaseUrl : `${supabaseUrl}/`;
  return new URL(`storage/v1/object/public/avatars/${storagePath}`, baseURL).toString();
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return jsonResponse(
      { error: "server_misconfigured", details: "Missing Supabase environment variables" },
      500,
    );
  }

  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) {
    return jsonResponse({ error: "missing_bearer_token" }, 401);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: authorization } },
  });
  const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: authData, error: authError } = await userClient.auth.getUser();
  const user = authData.user;
  if (authError || !user) {
    return jsonResponse(
      { error: "unauthorized", details: authError?.message ?? "Unable to resolve user" },
      401,
    );
  }

  let payload: FinalizePayload;
  try {
    payload = await request.json();
  } catch {
    return jsonResponse({ error: "invalid_json" }, 400);
  }

  const storagePath = normalizeStoragePath(payload.storage_path ?? "");
  if (!storagePath) {
    return jsonResponse({ error: "invalid_payload", details: "storage_path is required" }, 400);
  }
  if (!storagePath.startsWith(`${user.id}/`)) {
    return jsonResponse(
      { error: "forbidden_storage_path", details: "storage_path must begin with the authenticated user id" },
      403,
    );
  }
  const avatarUrl = buildCanonicalAvatarUrl(supabaseUrl, storagePath);

  let finalized: Record<string, unknown> | null = null;

  try {
    const { data, error } = await userClient.rpc("avatar_finalize_upload", {
      p_storage_path: storagePath,
      p_avatar_url: avatarUrl,
      p_mime_type: payload.mime_type ?? null,
      p_file_size: payload.file_size ?? null,
      p_width: payload.width ?? null,
      p_height: payload.height ?? null,
      p_crop_data: payload.crop_data ?? null,
      p_avatar_type: "upload",
    });
    if (error) {
      throw error;
    }
    if (!data || typeof data !== "object") {
      throw new Error("avatar_finalize_upload returned an empty payload");
    }
    finalized = data as Record<string, unknown>;
  } catch (error) {
    await serviceClient.storage.from("avatars").remove([storagePath]);
    return jsonResponse(
      {
        error: "avatar_finalize_failed",
        details: error instanceof Error ? error.message : String(error),
      },
      500,
    );
  }

  let authMetadataMirrored = true;
  let projectionStatus = String(finalized["projection_status"] ?? "projected");

  try {
    const { data: userRecord, error: userRecordError } = await serviceClient.auth.admin.getUserById(user.id);
    if (userRecordError || !userRecord.user) {
      throw userRecordError ?? new Error("Unable to load auth user for metadata mirror");
    }

    const existingMetadata = userRecord.user.user_metadata ?? {};
    const { error: updateError } = await serviceClient.auth.admin.updateUserById(user.id, {
      user_metadata: {
        ...existingMetadata,
        avatar_url: finalized["avatar_url"],
      },
    });
    if (updateError) {
      throw updateError;
    }

    projectionStatus = "projected_and_mirrored";
  } catch (error) {
    console.error("avatar-finalize metadata mirror failed", error);
    authMetadataMirrored = false;
    projectionStatus = "projected_only";
  }

  return jsonResponse({
    ...finalized,
    projection_status: projectionStatus,
    auth_metadata_mirrored: authMetadataMirrored,
  });
});
