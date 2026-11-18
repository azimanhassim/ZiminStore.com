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
  // DRAFT addition (needs migration 20261118 for zs_orphan_payment_proofs; NOT deployed):
  // remove payment-proof files that are older than 24 hours AND have no payments row
  // (e.g. the customer's insert failed after the upload). Two independent checks:
  //   1. the SQL helper only returns such files (24 h is a hard minimum there);
  //   2. here, each file is re-checked for age and, immediately before removal, for a
  //      payments row (a proof is never removed if any payments row points to it).
  // Skipped entirely if the helper is missing (migration not applied).
  const ORPHAN_MIN_AGE_MS = 24 * 3600_000;
  let orphanProofs = 0, orphanSkipped = 0;
  const { data: stray, error: strayErr } = await sb.rpc("zs_orphan_payment_proofs");
  if (!strayErr && stray?.length) {
    const old = (stray as { name: string; created_at: string }[])
      .filter((r) => r.name && Date.now() - new Date(r.created_at).getTime() > ORPHAN_MIN_AGE_MS);
    orphanSkipped += stray.length - old.length;
    const names = old.map((r) => r.name);
    if (names.length) {
      const { data: linked, error: linkErr } = await sb.from("payments").select("proof_path").in("proof_path", names);
      if (!linkErr) {
        const keep = new Set((linked ?? []).map((p: { proof_path: string }) => p.proof_path));
        const remove = names.filter((n) => !keep.has(n));
        orphanSkipped += names.length - remove.length;
        if (remove.length) {
          const { error: rmProofErr } = await sb.storage.from("payment-proofs").remove(remove);
          if (!rmProofErr) orphanProofs = remove.length;
        }
      }
    }
  }
  return Response.json({ found: docs?.length ?? 0, deleted, failed, orphan_proofs: orphanProofs, orphan_skipped: orphanSkipped });
});
