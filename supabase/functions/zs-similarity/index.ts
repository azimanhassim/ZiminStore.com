// ZiminStore similarity-provider adapter (Supabase Edge Function "zs-similarity").
// STATUS: DRAFT, NOT DEPLOYED.
//
// Purpose: one place where an OFFICIALLY AUTHORISED similarity API (e.g. a licensed
// Turnitin integration or another commercial provider) can be connected later.
// Today the only provider is "manual": an admin processes the document with an
// authorised service and uploads the PDF report in the portal.
//
// Rules this file enforces by design:
//   * No institutional logins, passwords, browser sessions or scraping.
//   * Provider API keys only from Edge Function Secrets (never the website or GitHub).
//   * Only signed-in admins may call it (checked against public.profiles.role).
import { createClient } from "npm:@supabase/supabase-js@2.117.3";

type Job = { providerJobId: string; status: "queued" | "processing" | "done" | "failed"; similarity?: number };
interface SimilarityProvider {
  readonly name: string;
  readonly configured: boolean;
  submit(input: { orderId: string; documentId: string; fileUrl: string; fileName: string }): Promise<Job>;
  status(providerJobId: string): Promise<Job>;
  fetchReport(providerJobId: string): Promise<Uint8Array>; // PDF bytes
}

class ManualProvider implements SimilarityProvider {
  readonly name = "manual";
  readonly configured = false;
  submit(): Promise<Job> { throw new Error("not_configured"); }
  status(): Promise<Job> { throw new Error("not_configured"); }
  fetchReport(): Promise<Uint8Array> { throw new Error("not_configured"); }
}

// Add a licensed provider here once a written agreement and API access exist, e.g.:
//   case "licensed-api": return new LicensedApiProvider(Deno.env.get("SIMILARITY_API_KEY")!);
function provider(): SimilarityProvider {
  switch (Deno.env.get("SIMILARITY_PROVIDER") ?? "manual") {
    default: return new ManualProvider();
  }
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  const auth = req.headers.get("Authorization") ?? "";
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } }, auth: { persistSession: false },
  });
  const { data: u } = await sb.auth.getUser();
  if (!u?.user) return json(401, { error: "unauthorised" });
  const { data: prof } = await sb.from("profiles").select("role").eq("id", u.user.id).maybeSingle();
  if (prof?.role !== "admin") return json(403, { error: "forbidden" });

  const p = provider();
  let body: { action?: string } = {};
  try { body = await req.json(); } catch { /* empty body = status */ }
  if (!body.action || body.action === "status") return json(200, { provider: p.name, configured: p.configured });
  if (!p.configured) return json(501, { error: "not_configured", provider: p.name });
  return json(400, { error: "bad_request" });
});
