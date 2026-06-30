# Admin Service

A Node.js/Express REST API providing admin-level management for orders, products, customers, affiliates, wholesale operations, and newsletter subscriptions. Backed by PostgreSQL (Supabase).

---

## Stack

| Layer | Technology |
|---|---|
| Runtime | Node.js >= 18 (ESM) |
| Framework | Express 4 |
| Database | PostgreSQL via `pg` (node-postgres) — hosted on Supabase |
| Auth | JWT (`jsonwebtoken`) + `bcryptjs` |
| File uploads | `multer` (payment screenshots) |
| Email | `nodemailer` |

---

## Getting Started

### 1. Install dependencies

```bash
npm install
```

### 2. Configure environment

Copy `.env.example` to `.env` and fill in the values:


Required variables:

```env
DATABASE_URL=
JWT_SECRET=
PUBLIC_BASE_URL=
CORS_ORIGIN=*
ADMIN_SERVICE_PORT=


```

### 3. Run

```bash
# Development (auto-restart on file change)
npm run dev

# Production
npm start
```

The server starts on port `5001` by default (configurable via `ADMIN_SERVICE_PORT`).

---

## API

Base URL: `http://localhost:5001`

All routes except `/health`, `/api/admin/login`, and the public `/api/products/*` endpoints require:

```
Authorization: Bearer <token>
```

Tokens are obtained via `POST /api/admin/login` and expire after 24 hours.

Full endpoint documentation is in **[API_REFERENCE.md](./API_REFERENCE.md)**.

### Route groups

| Prefix | Description |
|---|---|
| `POST /api/admin/login` | Authentication |
| `GET /api/admin/orders` | Order management (CRUD, status, promo, shipping, payment) |
| `GET /api/admin/stats` | Revenue and order statistics |
| `GET /api/admin/customers` | Customer management + credit system |
| `GET /api/admin/products` | Product CRUD + Klyme integration |
| `GET /api/admin/affiliates` | Affiliate programme management |
| `GET /api/admin/payment-links` | Payment capture requests |
| `GET /api/admin/address-change-requests` | Customer address change approvals |
| `GET /api/admin/wholesale/*` | Wholesale orders, inventory, team, recipes |
| `GET /api/admin/wholesale-inquiries` | Wholesale inquiry submissions |
| `GET /api/admin/newsletter` | Newsletter subscriber management |

---


## Project Structure

```
admin-service/
├── index.js                              # Main server — all routes and DB helpers
├── emailService.js                       # Nodemailer email helpers
├── package.json
├── .env                                  # Local environment (not committed)
├── .gitignore
├── API_REFERENCE.md                      # Full API documentation
├── admin-service.postman_collection.json # Postman test collection
├── admin-service.postman_environment.json
└── run-api-tests.js                      # Newman CLI runner
```

---

