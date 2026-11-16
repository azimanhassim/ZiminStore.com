// DRAF, BELUM DIPASANG. Padam fail dokumen pelanggan yang lebih 30 hari.
// Guna SERVICE_ROLE_KEY dari Edge Function Secrets sahaja (jangan letak dalam repo/index.html).
// Dicetus oleh pg_cron (lihat supabase/retention-30-days.sql) dengan header x-cleanup-secret.
import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  if (req.headers.get("x-cleanup-secret") !== Deno.env.get("CLEANUP_SECRET"))
    return new Response("forbidden", { status: 403 });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const cutoff = new Date(Date.now() - 30 * 86400_000).toISOString();
  const { data: orders, error } = await sb.from("orders").select("id").lt("created_at", cutoff).limit(500);
  if (error) return new Response(error.message, { status: 500 });
  let deleted = 0;
  for (const o of orders ?? []) {
    const { data: docs } = await sb.from("documents").select("id,storage_path").eq("order_id", o.id);
    const paths = (docs ?? []).map((d) => d.storage_path).filter(Boolean);
    if (!paths.length) continue;
    const { error: rmErr } = await sb.storage.from("customer-documents").remove(paths); // fail sebenar
    if (rmErr) continue;
    await sb.from("documents").update({ storage_path: "deleted" }).eq("order_id", o.id);
    deleted += paths.length;
  }
  return Response.json({ orders: orders?.length ?? 0, deleted });
});
