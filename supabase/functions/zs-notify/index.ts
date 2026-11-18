// ZiminStore notifications (Supabase Edge Function "zs-notify").
// DRAFT v4, NOT DEPLOYED. Live version is v3 (same behaviour minus the attempt log).
//
// Called by database triggers / the retry job (pg_net) with {type, id, attempt?, source?}:
//   payment_submitted  id = payments.id -> Telegram message to the admin
//   report_ready       id = orders.id   -> e-mail to the customer (Brevo)
// The request body is never trusted: the function re-reads the row with the
// service role, checks it really is in that state, and claims it once in
// public.zs_notification_log, so each event is sent at most once.
//
// NEW in v4 (report_ready only): every attempt is written to public.zs_order_events
//   notify_sent   Brevo accepted the e-mail (HTTP status, Brevo messageId)
//   notify_failed Brevo refused / unreachable (HTTP status, Brevo error code), or no e-mail address
// The log write never blocks or changes the e-mail itself; if the table does not
// exist yet (migration not applied) the e-mail still goes out as in v3.
// No customer e-mail address or name is stored in the log.
//
// Secrets (Dashboard -> Edge Functions -> Secrets), never in the website or GitHub:
//   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
//   BREVO_API_KEY, BREVO_SENDER_EMAIL, BREVO_SENDER_NAME (optional, default "ZiminStore")
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";

const SITE_URL = "https://azimanhassim.github.io/ZiminStore.com/";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type Env = (k: string) => string | undefined;
type Ctx = { attempt: number; source: string };

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const money = (sen: number) => "RM" + (Number(sen || 0) / 100).toFixed(2);
const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

async function claim(sb: SupabaseClient, kind: string, id: string) {
  const { data, error } = await sb.from("zs_notification_log")
    .upsert({ kind, ref_id: id }, { onConflict: "kind,ref_id", ignoreDuplicates: true })
    .select("ref_id");
  if (error) throw new Error("db_error");
  return !!data && data.length > 0;
}
const release = (sb: SupabaseClient, kind: string, id: string) =>
  sb.from("zs_notification_log").delete().eq("kind", kind).eq("ref_id", id);

// NEW: best-effort attempt log. Never throws.
async function logAttempt(sb: SupabaseClient, orderId: string, kind: "notify_sent" | "notify_failed",
                          detail: string, meta: Record<string, unknown>) {
  try {
    const { error } = await sb.from("zs_order_events").insert({ order_id: orderId, kind, detail: detail.slice(0, 500), meta });
    if (error) console.warn("zs_order_events insert skipped:", error.code ?? error.message);
  } catch (e) { console.warn("zs_order_events insert failed:", String(e)); }
}

async function paymentSubmitted(sb: SupabaseClient, id: string, env: Env, fetchFn: typeof fetch) {
  const token = env("TELEGRAM_BOT_TOKEN"), chatId = env("TELEGRAM_CHAT_ID");
  if (!token || !chatId) return json(500, { error: "telegram_not_configured" });
  const { data: pay, error } = await sb.from("payments")
    .select("id, order_id, customer_id, amount_sen, created_at").eq("id", id).maybeSingle();
  if (error) return json(500, { error: "db_error" });
  if (!pay) return json(404, { error: "not_found" });
  if (Date.now() - new Date(pay.created_at).getTime() > 60 * 60 * 1000) return json(200, { skipped: "too_old" });
  if (!(await claim(sb, "payment_submitted", pay.id))) return json(200, { skipped: "already_sent" });

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
  const r = await fetchFn(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text, disable_web_page_preview: true }),
  }).catch(() => null);
  if (!r || !r.ok) { await release(sb, "payment_submitted", pay.id); return json(502, { error: "telegram_failed", status: r?.status ?? 0 }); }
  return json(200, { sent: true });
}

async function reportReady(sb: SupabaseClient, id: string, env: Env, fetchFn: typeof fetch, ctx: Ctx) {
  const apiKey = env("BREVO_API_KEY"), from = env("BREVO_SENDER_EMAIL");
  if (!apiKey || !from) {
    await logAttempt(sb, id, "notify_failed", "Brevo belum dikonfigurasi", { ...ctx, reason: "brevo_not_configured" });
    return json(500, { error: "brevo_not_configured" });
  }
  const { data: order, error } = await sb.from("orders")
    .select("id, order_number, customer_id, document_count, status").eq("id", id).maybeSingle();
  if (error) return json(500, { error: "db_error" });
  if (!order) return json(404, { error: "not_found" });
  if (order.status !== "report_ready") return json(200, { skipped: "not_ready" });

  const { data: u, error: uErr } = await sb.auth.admin.getUserById(order.customer_id);
  const email = u?.user?.email;
  if (uErr || !email) {
    await logAttempt(sb, order.id, "notify_failed", "Akaun pelanggan tiada alamat e-mel", { ...ctx, reason: "no_email" });
    return json(200, { skipped: "no_email" });
  }
  if (!(await claim(sb, "report_ready", order.id))) return json(200, { skipped: "already_sent" });

  const { data: prof } = await sb.from("profiles").select("full_name").eq("id", order.customer_id).maybeSingle();
  const name = (prof?.full_name || "").trim();
  const n = order.document_count;
  const subject = `Laporan anda sudah siap — ${order.order_number}`;
  const textContent = [
    `Salam${name ? " " + name : ""},`,
    "",
    `Laporan similarity untuk pesanan ${order.order_number} (${n} dokumen) sudah siap.`,
    "Log masuk ke akaun ZiminStore anda untuk memuat turun laporan PDF:",
    SITE_URL,
    "",
    "Terima kasih kerana menggunakan ZiminStore.",
    "ZiminStore · Student Bantu Student",
  ].join("\n");
  const htmlContent = `<!doctype html><html><body style="margin:0;background:#050B1A;font-family:Arial,Helvetica,sans-serif;color:#EAF1FF">
<div style="max-width:520px;margin:0 auto;padding:28px 20px">
<div style="font-weight:800;font-size:18px;letter-spacing:.04em">ZIMIN<span style="color:#22D3EE">STORE</span></div>
<div style="margin-top:18px;background:#0D1D42;border:1px solid #23376B;border-radius:16px;padding:22px">
<p style="margin:0 0 12px">Salam${name ? " " + esc(name) : ""},</p>
<p style="margin:0 0 12px">Laporan similarity untuk pesanan <b>${esc(order.order_number)}</b> (${n} dokumen) <b style="color:#3DDC97">sudah siap</b>.</p>
<p style="margin:0 0 18px">Log masuk ke akaun ZiminStore anda untuk memuat turun laporan PDF.</p>
<a href="${SITE_URL}" style="display:inline-block;background:#2F6BFF;color:#ffffff;text-decoration:none;font-weight:700;padding:12px 20px;border-radius:10px">Buka akaun saya</a>
</div>
<p style="font-size:12px;color:#97A8CC;margin-top:16px">ZiminStore · Student Bantu Student. Laporan hanya boleh dimuat turun dari akaun anda.</p>
</div></body></html>`;

  let r: Response | null = null, netError = "";
  try {
    r = await fetchFn("https://api.brevo.com/v3/smtp/email", {
      method: "POST",
      headers: { "api-key": apiKey, "Content-Type": "application/json", "Accept": "application/json" },
      body: JSON.stringify({
        sender: { email: from, name: env("BREVO_SENDER_NAME") || "ZiminStore" },
        to: [{ email, ...(name ? { name } : {}) }],
        subject, htmlContent, textContent,
        tags: ["report_ready"],
      }),
    });
  } catch (e) { netError = String(e).slice(0, 120); }

  if (!r || !r.ok) {
    let brevoCode = "";
    try { brevoCode = r ? String((await r.json())?.code ?? "") : ""; } catch { /* body not JSON */ }
    await release(sb, "report_ready", order.id);
    await logAttempt(sb, order.id, "notify_failed",
      `E-mel gagal dihantar (Brevo ${r?.status ?? "tiada respons"}${brevoCode ? ", " + brevoCode : ""})`,
      { ...ctx, reason: r ? "brevo_failed" : "network", brevo_status: r?.status ?? 0, brevo_code: brevoCode || null,
        error: netError || null });
    return json(502, { error: "brevo_failed", status: r?.status ?? 0 });
  }

  let messageId: string | null = null;
  try { messageId = String((await r.json())?.messageId ?? "") || null; } catch { /* ignore */ }
  await logAttempt(sb, order.id, "notify_sent", `E-mel laporan siap dihantar (Brevo ${r.status})`,
    { ...ctx, brevo_status: r.status, message_id: messageId });
  return json(200, { sent: true });
}

export async function handle(req: Request, env: Env, fetchFn: typeof fetch = fetch) {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });
  let body: { type?: string; id?: string; attempt?: unknown; source?: unknown };
  try { body = await req.json(); } catch { return json(400, { error: "bad_json" }); }
  if (!body.id || !UUID.test(body.id)) return json(400, { error: "bad_request" });
  // Attempt/source are informational only (logged), never used for decisions.
  const ctx: Ctx = {
    attempt: Number.isInteger(body.attempt) && (body.attempt as number) > 0 && (body.attempt as number) < 100 ? body.attempt as number : 1,
    source: body.source === "retry" ? "retry" : "trigger",
  };
  const sb = createClient(env("SUPABASE_URL")!, env("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { fetch: fetchFn },
  });
  try {
    if (body.type === "payment_submitted") return await paymentSubmitted(sb, body.id, env, fetchFn);
    if (body.type === "report_ready") return await reportReady(sb, body.id, env, fetchFn, ctx);
  } catch { return json(500, { error: "db_error" }); }
  return json(400, { error: "bad_request" });
}

Deno.serve((req) => handle(req, (k) => Deno.env.get(k)));
