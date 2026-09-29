import { handleMaintenance } from "./handler.ts";

Deno.serve((request: Request) =>
  handleMaintenance(request, {
    url: Deno.env.get("SUPABASE_URL"),
    serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
    maintenanceToken: Deno.env.get("SKYBRIDGE_MAINTENANCE_TOKEN"),
  })
);
