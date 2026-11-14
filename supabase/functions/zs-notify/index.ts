// ZiminStore notifications (Supabase Edge Function "zs-notify").
//
// Called by the database (pg_net trigger) right after a customer submits a payment
// proof. It never trusts the request body: it only receives a payment id, re-reads
// the row with the service role, and records the notification in
// public.zs_notification_log so each payment is announced at most once.
//
// Secrets (Dashboard -> Edge Functions -> Secrets), never in the website or GitHub:
//   TELEGRAM_BOT_TOKEN   token from @BotFather
//   TELEGRAM_CHAT_ID     admin chat id
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
import { createClient } from "npm:@supabase/supabase-js@2.117.3";

const SITE_URL = "https://azimanhassim.github.io/ZiminStore.com/";
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const money = (sen: number) => "RM" + (Number(sen || 0) / 100).toFixed(2);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function handle(req: Request, env: (k: string) => string | undefined, fetchFn: typeof fetch = fetch) {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  let body: { type?: string; id?: string };
  try { body = await req.json(); } catch { return json(400, { error: "bad_json" }); }
  if (body.type !== "payment_submitted" || !body.id || !UUID.test(body.id)) return json(400, { error: "bad_request" });

  const token = env("TELEGRAM_BOT_TOKEN"), chatId = env("TELEGRAM_CHAT_ID");
  if (!token || !chatId) return json(500, { error: "telegram_not_configured" });
  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { fetch: fetchFn },
  });

  // 1. The payment must really exist and be recent (ignores replays of old ids).
  const { data: pay, error: payErr } = await sb.from("payments")
    .select("id, order_id, customer_id, amount_sen, status, created_at")
    .eq("id", body.id).maybeSingle();
  if (payErr) return json(500, { error: "db_error" });
  if (!pay) return json(404, { error: "not_found" });
  if (Date.now() - new Date(pay.created_at).getTime() > 60 * 60 * 1000) return json(200, { skipped: "too_old" });

  // 2. Claim it: only the first call for this payment continues.
  const { data: claimed, error: claimErr } = await sb.from("zs_notification_log")
    .upsert({ kind: "payment_submitted", ref_id: pay.id }, { onConflict: "kind,ref_id", ignoreDuplicates: true })
    .select("ref_id");
  if (claimErr) return json(500, { error: "db_error" });
  if (!claimed || claimed.length === 0) return json(200, { skipped: "already_sent" });

  // 3. Build the message from database values only.
  const [{ data: order }, { data: prof }] = await Promise.all([
    sb.from("orders").select("order_number, document_count, total_sen").eq("id", pay.order_id).maybeSingle(),
    sb.from("profiles").select("full_name").eq("id", pay.customer_id).maybeSingle(),
  ]);
  const when = new Date(pay.created_at).toLocaleString("ms-MY", { timeZone: "Asia/Kuala_Lumpur" });
  const text = [
    "🧾 Bukti bayaran baharu — ZiminStore",
    `Pesanan: ${order?.order_number ?? "-"}`,
    `Pelanggan: ${prof?.full_name || "(tiada nama)"}`,
    `Dokumen: ${order?.document_count ?? "-"} · Jumlah: ${money(order?.total_sen ?? pay.amount_sen)}`,
    `Masa: ${when}`,
    "",
    `Semak & sahkan: ${SITE_URL}`,
  ].join("\n");

  // 4. Send. If Telegram fails, release the claim so a retry can send it.
  const tg = await fetchFn(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text, disable_web_page_preview: true }),
  }).catch(() => null);
  if (!tg || !tg.ok) {
    await sb.from("zs_notification_log").delete().eq("kind", "payment_submitted").eq("ref_id", pay.id);
    return json(502, { error: "telegram_failed", status: tg?.status ?? 0 });
  }
  return json(200, { sent: true });
}

if (import.meta.main) Deno.serve((req) => handle(req, (k) => Deno.env.get(k)));
