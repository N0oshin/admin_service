# admin-service

Express + PostgreSQL (Supabase) backend powering the admin panel: order management, payment capture/refunds, affiliate program, wholesale console, customer credits, and transactional email.



## Getting started

```bash
npm install
npm run dev    # nodemon, auto-restart
npm start      # plain node
```

Requires Node ≥ 18. Configure `.env`
## Architecture notes

- **DB access**: a single `pg.Pool` 
- **Auth**: `requireAuth` middleware checks a `Bearer` JWT signed with `JWT_SECRET`. Every token embeds `sv: ADMIN_SESSION_VERSION`, a random value regenerated on every process start — **restarting the service invalidates all previously issued tokens**, forcing re-login.

- **File uploads**: `multer` (`adminUpload`, 25MB cap) writes admin payment-evidence screenshots to `UPLOADS_DIR`, served statically at `/uploads`.
- **Email**: all transactional email goes through `./emailService.js` (`sendEmail`, `sendCustomerInfoEmail`, `sendHasInvoiceEmail`, `sendIbalticxEmail`, `sendNewsletterWinnerEmail`, `sendOutForDeliveryEmail`, `sendPaymentDeclinedEmail`, `sendPaymentReminderEmail`, `sendPaymentSuccessfulEmail`, `sendRefundInitiatedEmail`).
- **External payment providers**: AabanPay (card refunds), Klyme and iBalticX (referenced in payment status/config logic).

## Environment variables

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `DATABASE_URL` | **Yes** | — | Postgres (Supabase) connection string. |
| `JWT_SECRET` | **Yes** | — | Secret for signing/verifying admin JWTs.|
| `ADMIN_SERVICE_PORT` / `PORT` | No | `5001` | HTTP listen port. |
| `CORS_ORIGIN` | No | `*` | `*` or comma-separated allowlist of origins. |
| `UPLOADS_DIR` | No | `/var/www/backend/uploads` | Filesystem path for uploaded payment-evidence files. |
| `PUBLIC_BASE_URL` / `PUBLIC_API_BASE_URL` | No | — | Used to build customer-facing links (retry-payment, track-order, email asset URLs). |
| `DB_POOL_LIMIT` | No | `10` | Max Postgres pool connections. |
| `DOTENV_PATH` | No | — | Explicit `.env` path override; otherwise searches up to 4 parent dirs from `index.js`. |
| `AABANPAY_API_KEY` | For refunds | — | AabanPay API key (Basic auth) for card refunds. |
| `AABANPAY_REFUND_BASE` | No | `https://aabanpay.com/rest/v1/transactions/refund` | AabanPay refund endpoint base URL. |
| `PAYMENT_CAPTURE_VERIFY_TIMEOUT_MS` | No | `25000` | Timeout for outbound payment-verification fetches. |
| `AFFILIATE_DEFAULT_REWARD` | No | `40` | Default affiliate reward (GBP) granted per qualifying order. |
| `ALLOW_BULK_EMAIL_TEST` | For bulk send | — | Must be `'true'` to permit `/api/admin/email/customer-info/send-all`. |
| `ADMIN_SEED_USERNAME` / `ADMIN_SEED_EMAIL` / `ADMIN_SEED_PASSWORD` | First boot | — | Used to seed the first row of `admin_users` if the table is empty. Logs a warning if unset (no fallback credentials). |

## Authentication

- `POST /api/admin/login` — `{ username, password }` → bcrypt-checked against `admin_users`, returns a JWT (24h expiry, embeds `sv: ADMIN_SESSION_VERSION`). Updates `admin_users.last_login` (non-fatal if it fails).
- `GET /api/admin/verify` *(auth)* — validates the bearer token, returns the decoded admin user.
- All other `/api/admin/*` routes require `Authorization: Bearer <token>` via `requireAuth`, **except** the public Klyme-status lookups and the public health check (noted below).

## Routes by feature area



### Orders — CRUD &amp; lifecycle

| Method &amp; path | Purpose | Side effects |
|---|---|---|
| `POST /api/admin/orders` *(multipart: `adminPaymentScreenshot`)* | Manually creates an order: validates customer/shipping/items, generates a unique order number, optionally applies store credit (capped to wallet balance). | Inserts `orders`, `order_items`, a `Manual` `payments` row; may update `user_credits`/`credit_ledger`; saves screenshot to `/uploads`. Transactional. |
| `GET /api/admin/orders` | Paginated order list with derived columns: latest payment status, latest success/fail status, computed `effective_payment_status`, capture-request sent timestamp, resolved `payment_date`. | Read-only. |
| `GET /api/admin/order/:id` | Single order by numeric id + items + payments. | Read-only. |
| `GET /api/admin/order-number/:orderNumber` | Single order by order number + items + payments. | Read-only. |
| `GET /api/admin/orders/latest-by-email/:email` | Most recent order for a customer email + items + payments. | Read-only. |
| `PUT /api/admin/order/:id/items` | Replaces an order's line items (update/insert/delete), recalculates subtotal/discount/total, syncs `payments.amount`. | Writes `order_items`, `orders`, `payments`. Transactional, row-locked. |
| `PUT /api/admin/order/:id/promo` | Applies/clears a promo code from a hardcoded code→percent map (`PETER10`, `SAVE20`, `CHARLES99`, `REFUND25`, etc.), recalculates discount/total, syncs `payments.amount`. | Writes `orders`, `payments`. Transactional, row-locked. |
| `PUT /api/admin/order/:id/shipping` | Updates shipping address fields (only columns that exist on `orders`). | Writes `orders`. Transactional, row-locked. |
| `PUT /api/admin/order/:id/payment-status` | Marks payment `received` or `rejected` via the shared `applyAdminPaymentStatusUpdate` helper. | Delegates DB writes + emails (success/decline) + affiliate reward grant/revoke. |
| `POST /api/admin/order/:id/payment-status/evidence` *(multipart)* | Approves payment with required admin remark + optional screenshot; marks `received`, fire-and-forget side effects. | Saves screenshot; delegates to `applyAdminPaymentStatusUpdate`. |
| `PUT /api/admin/order/:id/status` | Updates `status`, optionally `tracking_number` and/or `payment_status`. Sends shipping email on transition to "out for delivery" with a tracking number. | Writes `orders`; conditionally `sendOutForDeliveryEmail`. |
| `DELETE /api/admin/order/:id` | Deletes an order (FK cascade removes items/payments). | Deletes `orders` (cascade). |
| `POST /api/admin/order/:id/refund` | Refunds a card payment via AabanPay — **restricted to orders where every item is product_id `32`** (test product). | Calls AabanPay refund API; `sendRefundInitiatedEmail`; writes `orders`, `payments`. |

### Payment capture &amp; reminders

| Method &amp; path | Purpose | Side effects |
|---|---|---|
| `POST /api/admin/orders/:orderNumber/capture-payment` | Generates a single-use payment-capture token, emails the customer a payment link (HSA INTERPAY bank details). | Inserts `payment_capture_requests`; sends `payment_capture` template email. |
| `POST /api/admin/orders/bulk-capture-payment` | Batch version (max 500 order numbers); skips orders that already have a pending capture request. | Inserts `payment_capture_requests`; sends emails per order. |
| `POST /api/admin/orders/bulk-payment-reminder` | Batch version that always issues a new token and sends a reminder (no skip-if-existing). | Inserts `payment_capture_requests`; `sendPaymentReminderEmail` per order. |
| `GET /api/admin/payment-links` | Lists capture-request records sent within a window (1/12/24h), with derived status (`pending`/`received`/`rejected`). | Read-only. |

### Invoices / HAS (mostly disabled)

| Method &amp; path | Purpose | Side effects |
|---|---|---|
| `POST /api/admin/orders/:orderNumber/resend-has-invoice` | **Disabled** — always `410`. HAS/IVMS invoice emails are policy-blocked. | None. |
| `POST /api/admin/orders/:orderNumber/resend-old-has-invoice` | Rebuilds/resends a legacy "HAS invoice" email (LHAS/HSA INTERPAY details). Hardcoded recipient `its.me.rushil2002@gmail.com` (testing only). | `sendHasInvoiceEmail`. No DB writes. |
| `POST /api/admin/orders/:orderNumber/send-has-invoice-to` | Same invoice logic, sends to an arbitrary admin-supplied address (for manual testing); blocks `accounts@ivmsgroup.com`. Choice of `current`/`old` bank-detail variant. | `sendHasInvoiceEmail`. No DB writes. ⚠️ has the undefined-`baseUrl` bug noted above. |
| `POST /api/admin/send-has-invoice` | **Disabled** — always `410`. | None. |
| `POST /api/admin/orders/:orderNumber/resend-has-entry` | **Disabled** — always `410`. | None. |
| `POST /api/admin/orders/resend-all-has-entries` | **Disabled** — always `410`. | None. |
| `POST /api/admin/email/has-invoice/send` | **Disabled** — always `410`. | None. |

### Stats / dashboard

| Method &amp; path | Purpose |
|---|---|
| `GET /api/admin/stats` | Large dashboard aggregate: total orders/revenue, pending/completed counts, pending vs completed payment totals, capture-link send counts (1h/12h/24h/7d/total), received-payment counts/amounts over multiple windows, broken out by provider (iBalticX, Klyme, AabanPay) and bank account used. |
| `GET /api/admin/stats/orders-submitted` | Orders created in the last 1h/12h/24h/7d. |
| `GET /api/admin/stats/completed-payments` | Completed-payment counts/sums over 1h/12h/24h/7d. |
| `GET /api/admin/stats/product` | Per-product/SKU sales stats (orders, units, revenue) over 1h/12h/24h/7d. `productId` or `sku` query required. |
| `GET /api/admin/stats/weekly` | Day-by-day series (default 7, max 30 days) of requested/submitted/secured/received/completed counts &amp; amounts, UTC-bucketed. |
| `GET /api/admin/stats/timeseries` | Auto-detects full order-history date range, returns day- or month-bucketed series (`bucket=auto\|day\|month`; auto-switches to month past 90-day span). |
| `GET /api/admin/ibalticx-paid` | Orders paid via the iBalticX bank account, with shipping/invoice metadata. |
| `GET /api/admin/klyme-paid` | Orders paid via Klyme, joined to latest matching `payments` row. |

All stats routes are read-only.

### Customers, credits &amp; blacklist

| Method &amp; path | Purpose | Side effects |
|---|---|---|
| `GET /api/admin/customers` | Aggregated customer list grouped by email, with order count and most recent order. ⚠️ uses MySQL-only `SUBSTRING_INDEX`/`GROUP_CONCAT` — likely broken on Postgres. | Read-only. |
| `GET /api/admin/customers/:email` | Single customer profile: order stats, credit balance, last 20 orders. | Read-only (ensures credits schema). |
| `POST /api/admin/customers/:email/credits` | Adds store credit (creates wallet row if absent). | Writes `user_credits`, `credit_ledger` (source `admin_add`). Transactional, row-locked. |
| `POST /api/admin/customers/:email/credits/deduct` | Deducts store credit, capped at current balance. | Writes `user_credits`, `credit_ledger` (source `admin_deduct`). Transactional, row-locked. |
| `GET /api/admin/customer-blacklist` | Lists blacklisted customers joined to most recent matching order. | Read-only. |
| `DELETE /api/admin/customer-blacklist/:id` | Removes a blacklist entry. | Deletes `customer_blacklist`. |

### Products &amp; Klyme config

| Method &amp; path | Auth | Purpose | Side effects |
|---|---|---|---|
| `GET /api/admin/products` | Yes | Lists storefront products (optional search `q`) with images. | Read-only. |
| `GET /api/admin/products/:id` | Yes | Single product by id, with images. | Read-only. |
| `POST /api/admin/products` | Yes | Creates a product (auto-generates a unique slug from name, dedupes on SKU/slug), inserts images, syncs `product_config`. | Inserts `products`, `product_images`, upserts `product_config`. Transactional. |
| `PUT /api/admin/products/:id` | Yes | Updates a product (patch-style: only sent fields change), replaces images if `images` array sent, re-dedupes SKU, syncs `product_config`. | Updates `products`; rewrites `product_images`; upserts `product_config`. Transactional, row-locked. |
| `DELETE /api/admin/products/:id` | Yes | Deletes a product and its images/config. | Deletes `products`, `product_images`, `product_config`. Transactional, row-locked. |
| `GET /api/admin/product-config` | Yes | Lists Klyme-related product config. | Read-only. |
| `POST /api/admin/product/:id/klyme-enabled` | Yes | Enables/disables Klyme for one product (upsert into `product_config`). | Writes `product_config`. |
| `POST /api/admin/products/klyme-status` | **No** (public) | Bulk Klyme-enabled lookup by product id, used at checkout. Force-enables Klyme for a hardcoded retatrutide allowlist regardless of DB value. | Read-only. |
| `POST /api/products/klyme-status` | **No** (public) | Same, alternate path. | Read-only. |
| `POST /api/admin/products/klyme-status-by-sku` | **No** (public) | Bulk Klyme-enabled lookup by SKU; force-enables `RETAT-20MG`/`RETAT-40MG`. | Read-only. |
| `POST /api/products/klyme-status-by-sku` | **No** (public) | Same, alternate path. | Read-only. |

### Affiliates

| Method &amp; path | Purpose | Side effects |
|---|---|---|
| `GET /api/admin/affiliate-requests` | Lists affiliate signup requests, filterable by status (default `pending`). | Read-only. |
| `POST /api/admin/affiliate-requests/:id/approve` | Approves a request: generates a unique promo code, upserts `promo_codes` (source `affiliate`), upserts `affiliates` (default reward £10). | Writes `promo_codes`, `affiliate_requests`, `affiliates`. |
| `POST /api/admin/affiliate-requests/:id/reject` | Rejects a pending request. | Updates `affiliate_requests`. |
| `POST /api/admin/affiliate-requests/:id/revoke` | Revokes an approved affiliate: deactivates promo code, sets affiliate status `revoked`. | Updates `affiliate_requests`, `promo_codes`, `affiliates`. |
| `POST /api/admin/affiliate-requests/:id/reinstate` | Reverses a revoke. | Updates `affiliate_requests`, `promo_codes`, `affiliates`. |
| `GET /api/admin/affiliates` | Lists affiliates with wallet balance and redemption aggregates. | Read-only. |
| `GET /api/admin/affiliates/_debug` | Diagnostic counts/samples across the affiliate pipeline (must be registered before `/affiliates/:id`). | Read-only. |
| `POST /api/admin/affiliates/_backfill` | Retroactively grants rewards for already-paid orders missing a redemption row. Idempotent; self-referral/dedup guarded (must be registered before `/affiliates/:id`). | Writes `user_credits`, `credit_ledger`, `promo_redemptions` per qualifying order. |
| `GET /api/admin/affiliates/:id` | Affiliate detail: profile, wallet, all redemptions joined to orders + items. | Read-only. |

Reward logic lives in two shared helpers used by the live flow, the backfill route, and `applyAdminPaymentStatusUpdate`:
- `grantAffiliateRewardForReceivedOrder(connection, order, opts)` — validates promo/email/self-referral, dedupes by `(affiliate_user_id, customer_email)` and `order_id`, credits the wallet, logs `credit_ledger`, inserts `promo_redemptions`.
- `revokeAffiliateRewardForRejectedOrder(connection, order)` — reverses a grant (wallet can go negative), writes a negative ledger entry, deletes the redemption row.

### Address change requests

| Method &amp; path | Purpose | Side effects |
|---|---|---|
| `GET /api/admin/address-change-requests` | Lists customer-submitted shipping-address change requests. | Read-only. |
| `POST /api/admin/address-change-requests/:id/approve` | Approves one request, writes new shipping fields onto the order. Delegates to `approveAddressChangeRequestById`. | Updates `orders`, `order_address_change_requests`. Transactional. |
| `POST /api/admin/address-change-requests/:id/reject` | Rejects one request. | Updates `order_address_change_requests`. |
| `POST /api/admin/address-change-requests/approve-all` | Bulk-approves all pending requests (loops the single-approve helper). | Same as single approve, per row. |
| `POST /api/admin/address-change-requests/reject-all` | Bulk-rejects all pending requests. | Updates `order_address_change_requests`. |

### Wholesale console

| Method &amp; path | Purpose | Side effects |
|---|---|---|
| `GET /api/admin/wholesale-inquiries` | Lists wholesale contact-form inquiries. | Read-only. |
| `DELETE /api/admin/wholesale-inquiries/:id` | Deletes one inquiry. | Deletes `wholesale_inquiries`. |
| `GET /api/admin/wholesale/products` | Lists active wholesale products. | Read-only. |
| `GET /api/admin/wholesale/team` | Lists active wholesale team members. | Read-only. |
| `GET /api/admin/wholesale/inventory/raw` | Lists raw materials + current stock. | Read-only. |
| `PUT /api/admin/wholesale/inventory/raw` | Bulk upserts raw-material stock levels (max 50 updates). | Upserts `wholesale_raw_material_stock`. |
| `GET /api/admin/wholesale/orders` | Lists wholesale orders (filter by `status`/`country`), with nested items. | Read-only. |
| `GET /api/admin/wholesale/orders/:id` | Single wholesale order detail + items + work allocations. | Read-only. |
| `POST /api/admin/wholesale/orders` | Creates a wholesale order; validates items against the product catalog, computes totals. | Inserts `wholesale_orders`, `wholesale_order_items`. Transactional. |
| `PUT /api/admin/wholesale/orders/:id` | Partial update (name, email, mobile, country, deliveryDate, status, notes). | Updates `wholesale_orders`. |
| `DELETE /api/admin/wholesale/orders/:id` | Deletes a wholesale order and dependent allocations/items. | Deletes from 3 tables. |
| `POST /api/admin/wholesale/orders-with-deduction` | Creates an order AND deducts raw-material inventory by country per product recipe; validates sufficient stock first; rejects if any recipe/inventory row is missing. | Decrements `wholesale_product_inventory`; inserts order + items. Transactional. |
| `POST /api/admin/wholesale/allocations` | Assigns order-item quantity to a team member; validates remaining unassigned quantity; decrements 7 raw materials per unit; auto-flips order `pending` → `in_progress`. | Inserts `wholesale_work_allocations`; decrements stock; updates order status. Transactional. |
| `GET /api/admin/wholesale/product-inventory` | Lists per-(product, country) inventory, optional filters. | Read-only. |
| `PUT /api/admin/wholesale/product-inventory` | Upserts per-(product, country) component counts (cartridge/leaflet/magnet_box/pen/solution/needles/powder). | Upserts `wholesale_product_inventory`. |
| `GET /api/admin/wholesale/product-recipes` | Lists bill-of-materials recipes. | Read-only. |
| `GET /api/admin/wholesale/countries` | Static hardcoded list of 10 countries. | None. |

### Ad hoc / templated email sending

| Method &amp; path | Purpose | Side effects |
|---|---|---|
| `POST /api/admin/email/customer-info/send` | Sends a "customer info" email to one address. | `sendCustomerInfoEmail`. |
| `POST /api/admin/email/template/send` | Sends a generic templated email by `type`. | `sendEmail`. |
| `POST /api/admin/email/ibalticx/send` | Sends an iBalticX-formatted invoice with masked line items. | `sendIbalticxEmail`. |
| `POST /api/admin/email/payment-reminder/send` | Sends a standalone payment-reminder email. | `sendPaymentReminderEmail`. |
| `POST /api/admin/email/customer-info/send-all` | Bulk-sends "customer info" email to every distinct customer email in `orders`. Gated by `ALLOW_BULK_EMAIL_TEST=true`; supports `dryRun`. | Sequential `sendCustomerInfoEmail` calls (max 5000, default 500). |

### Newsletter

| Method &amp; path | Purpose | Side effects |
|---|---|---|
| `GET /api/admin/newsletter` | Lists subscribers, searchable (`q`) and date-filterable (`from`/`to`), paginated + total count. | Read-only. |
| `DELETE /api/admin/newsletter/:id` | Deletes one subscriber. | Deletes `newsletter_subscribers`. |
| `PUT /api/admin/newsletter/:id/winner` | Flags/unflags a giveaway winner; fires celebration email only on false→true transition. | Updates `newsletter_subscribers`; `sendNewsletterWinnerEmail` (fire-and-forget; product name hardcoded). |
| `GET /api/admin/newsletter/export.csv` | Exports filtered subscriber list as CSV (same filters, no pagination). | Read-only. ⚠️ has the `e$1.message` typo bug noted above. |

### Misc

| Method &amp; path | Auth | Purpose |
|---|---|---|
| `GET /health` | No | DB liveness probe (`SELECT 1`). |

## Key shared helpers

| Function | Purpose |
|---|---|
| `dbQuery(sql, params)` / `dbQueryConn(client, sql, params)` | Postgres query wrappers returning a mysql2-style `[rows]` / `[{affectedRows, insertId}]` tuple. |
| `requireAuth(req, res, next)` | JWT auth middleware; rejects tokens issued before the last service restart (`ADMIN_SESSION_VERSION` mismatch). |
| `applyAdminPaymentStatusUpdate({...})` | Central handler for all admin-driven payment-status transitions (received/rejected): updates the order, sends success/decline email with retry-payment token, grants/revokes affiliate reward. |
| `grantAffiliateRewardForReceivedOrder` / `revokeAffiliateRewardForRejectedOrder` | Affiliate wallet credit grant/reversal, shared by the live flow, `_backfill`, and `applyAdminPaymentStatusUpdate`. |
| `approveAddressChangeRequestById(requestId, adminId, adminNote)` | Transactional approval of one address-change request; used by both the single and bulk "approve" routes. |
| `generateUniqueAffiliatePromoCode(connection, userName, percent)` | Builds a collision-checked promo code like `A<FIRSTNAME><PERCENT>`. |
| `aabanpayRefundTransaction({ transactionId, amount })` | Calls AabanPay's refund REST API. |
| `columnExists(table, column)` | Generic `information_schema.columns` existence check, used throughout to support both legacy and current schema shapes. |
| `ensure*Table()` / `ensure*Schema()` (~20 functions) | Idempotent startup bootstrap — creates tables and backfills columns if missing. See `index.js` bottom IIFE for the run order. |

