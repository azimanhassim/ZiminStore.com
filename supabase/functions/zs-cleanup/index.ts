// ZiminStore: padam fail dokumen pelanggan 30 hari selepas pesanan dibuat (janji notis PDPA).
// Dicetus setiap hari oleh pg_cron (supabase/retention-30-days.sql).
// Tiada secret dan tiada input: fungsi ini hanya boleh buat satu perkara (padam fail yang
// sudah melepasi 30 hari), jadi panggilan luar tidak boleh memadam apa-apa yang lain.
// SUPABASE_SERVICE_ROLE_KEY dibekalkan automatik oleh Supabase; ia tidak ada dalam repo.
// Baris `documents` dikekalkan (nama fail untuk rekod); storage_path ditanda 'deleted/<id>'.
import { createClient } from "npm:@supabase/supabase-js@2";

const DAYS = 30;

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const cutoff = new Date(Date.now() - DAYS * 86400_000).toISOString();
  const { data: docs, error } = await sb
    .from("documents")
    .select("id,storage_path,orders!inner(created_at)")
    .lt("orders.created_at", cutoff)
    .not("storage_path", "like", "deleted/%")
    .limit(500);
  if (error) return Response.json({ error: error.message }, { status: 500 });

  let deleted = 0, failed = 0;
  for (const d of docs ?? []) {
    const { error: rmErr } = await sb.storage.from("customer-documents").remove([d.storage_path]);
    if (rmErr) { failed++; continue; }
    const { error: upErr } = await sb.from("documents").update({ storage_path: `deleted/${d.id}` }).eq("id", d.id);
    if (upErr) failed++; else deleted++;
  }
  // DRAFT addition (needs migration 20261118 for zs_orphan_payment_proofs; not deployed):
  // remove payment-proof files older than 24 h that never got a payments row
  // (e.g. the customer's insert failed after the upload). Skipped if the helper is missing.
  let orphanProofs = 0;
  const { data: stray, error: strayErr } = await sb.rpc("zs_orphan_payment_proofs");
  if (!strayErr && stray?.length) {
    const names = stray.map((r: { name: string }) => r.name);
    const { error: rmProofErr } = await sb.storage.from("payment-proofs").remove(names);
    if (!rmProofErr) orphanProofs = names.length;
  }
  return Response.json({ found: docs?.length ?? 0, deleted, failed, orphan_proofs: orphanProofs });
});
