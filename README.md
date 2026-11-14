# ZiminStore.com

Static website for **ZiminStore**, a Turnitin similarity-check service for students
(RM3.50 per document, PDF report). One HTML file, with Supabase for
accounts, orders, file storage and the admin dashboard.

> ZiminStore is an independent service and is not affiliated with, sponsored by or
> endorsed by Turnitin, LLC.

## Files

| Path | Purpose |
|---|---|
| `index.html` | The whole site: landing page, customer portal, admin dashboard. |
| `supabase/introspect.sql` | Read-only queries to inspect the live database. Changes nothing. |
| `supabase/audit-final.sql` | Read-only, **one** query: PASS / FAIL / SEMAK table for RLS, role, price, payment, storage and admin access, plus the full policy/trigger/function inventory. Run this first. |
| `assets/music/` | Background track for the ZiminStore Music player (original composition) and its README. |
| `tools/compose-study-night.py` | Script that generated the original track (proof of origin; re-run to regenerate). |
| `supabase/optional-cleanup.sql` | Optional tidy-ups from the audit. **Not applied.** Nothing in it is required for security. |

## Configuration

All settings live in the `CONFIG` object near the bottom of `index.html`.

| Key | Value |
|---|---|
| `supabaseUrl` | `https://vletiqtwzzrktttzxyej.supabase.co` |
| `supabasePublishableKey` | Public publishable key. Safe in browser code **only** while RLS is correct. |
| `whatsappNumber` | **TODO** before launch, e.g. `60123456789` |
| `paymentQrUrl` | **TODO** before launch: URL of your DuitNow QR image |
| `pricePerDocSen` | Display only. The real price (350 sen) lives in the `zs_prepare_order` trigger **and** the `zs_orders_insert` policy: change all three together. |

**Never** put the `service_role` / secret key in this repository or in `index.html`.

## Database

Confirmed against the live project with `supabase/audit-final.sql` (12 Nov 2026):
**101 PASS, 0 FAIL, 0 SEMAK**. `index.html` relies on the following.

**Tables (schema `public`)**

| Table | Columns used by the site |
|---|---|
| `profiles` | `id` (= `auth.users.id`), `full_name`, `phone`, `role` (`customer` / `admin`) |
| `orders` | `id`, `order_number`, `customer_id`, `document_count`, `total_sen`, `status`, `created_at`, `updated_at` |
| `documents` | `id`, `order_id`, `customer_id`, `original_filename`, `storage_path`, `file_type` (`pdf` / `docx`) |
| `payments` | `id`, `order_id`, `customer_id`, `amount_sen`, `proof_path`, `status` (`pending` / `verified` / `rejected`), `verified_at`, `created_at` |
| `reports` | `id`, `order_id`, `document_id`, `customer_id`, `report_path` |

**Relationships:** `documents.order_id`, `payments.order_id` and `reports.order_id`
must be foreign keys to `orders.id`; the portal loads them as nested data in one request.
`reports.document_id` → `documents.id`.

**Order status values:** `pending_payment`, `payment_verified`, `processing`,
`report_ready`, `action_required`, `cancelled`.

**Storage buckets (all private):**

| Bucket | Contents | Limit |
|---|---|---|
| `customer-documents` | Customer PDF/DOCX | 20 MB, PDF/DOCX |
| `payment-proofs` | Payment receipts | 5 MB, JPG/PNG/PDF |
| `similarity-reports` | Admin-uploaded reports | 20 MB, PDF |

File paths are always `<customer_id>/<order_id>/<uuid>-<filename>`.

## Security model

Enforced in the database (the browser is never trusted):

* **Role:** new accounts are always `customer` (`zs_handle_new_user`). The
  `zs_profiles_update` policy only lets a customer save their own profile with
  `role = 'customer'`. Admins are made in the SQL Editor.
* **Price / status:** `zs_orders_prepare` trigger sets `total_sen = document_count × 350`
  and `status = 'pending_payment'`; the `zs_orders_insert` policy rejects anything else.
  Only admins can update orders.
* **Payments:** customers can only insert `status = 'pending'` for their own order, after
  the proof file exists (`zs_payments_prepare`). Only admins can verify/reject
  (`zs_payments_update_guard` also blocks changing amount, order or file).
* **Files:** all three buckets are private with size/type limits. Customers can only read
  and upload in their own `<customer_id>/` folder; reports are downloadable only when a
  `reports` row belongs to them. Only admins upload reports, overwrite or delete files.
* **Order status after review:** the database has no trigger for this. The admin portal
  sets `payment_verified` after verifying, and `processing` / `report_ready` after each
  report (counting distinct documents). Allowed by admin-only RLS.

Make yourself admin (SQL Editor only):

```sql
update public.profiles set role = 'admin' where id = '<your auth user id>';
```

## Supabase dashboard settings to check

* **Authentication → URL Configuration:** set Site URL to `https://ziminstore.com` and add
  `https://ziminstore.com/**` (and any preview URL) to Redirect URLs, otherwise password
  reset links will not return to the site.
* **Authentication → Providers → Email:** keep "Confirm email" on.
* **Authentication → Rate limits / CAPTCHA:** consider enabling CAPTCHA for sign-up.

## ZiminStore Music player

A small floating player (bottom-right, above the WhatsApp button; a round button on phones).
It is a separate component in `index.html`: `<style id="zs-music-style">`, the `#zs-music`
markup and `<script id="zs-music-script">`. It never autoplays, keeps one audio instance,
pauses other tabs, follows the BM/EN switch and sits underneath the customer/admin portal.
Change or disable the track in the `ZS_MUSIC` config (see `assets/music/README.md`).

## Notifications (Supabase Edge Function `zs-notify`)

* **Admin:** Telegram message when a customer submits a payment proof.
* **Customer:** e-mail (Brevo) when an order becomes `report_ready`, with a link to log in
  and download the report (the PDF itself is never attached).

Database triggers (`supabase/migrations/20261114_telegram_payment_notify.sql`) call the
function through `pg_net`; the function re-reads the row and logs each event once in
`zs_notification_log`, so nothing is sent twice and fake calls do nothing.

Secrets live only in **Supabase → Edge Functions → Secrets** (never in `index.html`,
GitHub or chat): `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `BREVO_API_KEY`,
`BREVO_SENDER_EMAIL`, `BREVO_SENDER_NAME` (optional). Deploy with **verify JWT off**:
the database calls it without a user token and the function validates every request itself.

## Local preview

Open `index.html` directly in a browser, or serve the folder:

```sh
python3 -m http.server 8080
```

## Deployment

Not deployed yet. Any static host works (GitHub Pages, Netlify, Cloudflare Pages, Vercel).
