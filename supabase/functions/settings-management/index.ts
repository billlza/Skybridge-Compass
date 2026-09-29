import { handleSettings } from "./handler.ts";

Deno.serve((request: Request) =>
  handleSettings(request, {
    url: Deno.env.get("SUPABASE_URL"),
    anonKey: Deno.env.get("SUPABASE_ANON_KEY"),
  })
);
