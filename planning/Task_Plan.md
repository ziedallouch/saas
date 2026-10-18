# ERP SaaS — Task Plan

Phased breakdown, roughly sequential but with overlap possible between phases 2–4.

## Decisions locked in

These are settled — do not re-litigate during build:

| Decision | Choice |
|---|---|
| Tenancy model | **Hybrid, launching shared**: one DB + `tenant_id` + RLS; `isolation_mode` field and tenant resolution layer built day one |
| Keycloak scope | **Pure IdP** — issues `tenant_id` + `roles` only; no pack/subscription data ever synced in |
| Entitlement resolution | **Gateway reads Redis once per request**, forwards result in trusted context; services re-check from context, never call Redis again |
| Cache layering | **None at launch** — no in-process cache on top of Redis |
| Cache invalidation | Event-driven bust on subscription change; TTL (30–60s) is the safety net |
| Missing entitlement context | **Fail closed — deny** |
| Module downgrade | **Soft-lock** — data untouched, access blocked in entitlement layer |
| Tenant deletion | **Staged**: suspended → soft-deleted (30–90d grace) → hard delete |
| Stack | **Angular** (frontend) · **NestJS** (backend) · **PostgreSQL** · Keycloak · Redis · Kubernetes |
| Next.js | **Rejected** — React frontend framework; with Angular it is a bare API server lacking DI, guards, job scheduling |
| First module | **HR**, with a second module immediately after |
| Keycloak realms | **Single shared realm, tenant = group**; `tenant_id` as a *group* attribute. Realm-per-tenant deferred to the same enterprise trigger as dedicated DBs |
| Authorization model | **RBAC + scope** (`self`/`department`/`tenant`). ABAC rejected |
| Permission format | Fixed `module.resource.action` convention, locked before the first module ships |
| Custom tenant roles | **Application DB, never Keycloak.** `UNIQUE (tenant_id, name)` makes cross-tenant name collisions structurally impossible |
| Permissions in token | **Never** — resolved server-side, cached in Redis |
| Navigation | Server-composed from entitlement ∩ permissions. **Not-entitled = greyed + upgrade prompt; no-permission = hidden entirely.** Never collapse the two |
| Entitlement unit | **Feature**, not module — packs may include HR with or without Payroll. Routes declare `@RequireFeature` |
| Feature registration | **Versioned manifest + migration**, never runtime self-registration. New features inert until an admin assigns them to a pack |
| Feature deletion | **Never hard-delete** — mark deprecated. Active subscriptions and historical invoices reference them |
| Platform roles | In **Keycloak** (unlike tenant roles). Feature-assignment and price-setting are **separate** permissions |
| Platform vs tenant realm | **One realm, separated by roles.** Token has either `tenant_id` or a platform role — **never both** |
| Payroll | **Deferred** out of HR MVP — most locale-specific, largest scope risk |
| Internal transport | **REST over HTTP/JSON.** gRPC buys typed contracts and lower latency, and costs proto tooling, codegen in CI, and harder debugging. Nothing here is latency-bound: the gateway reads Redis once per request and services re-check from the context envelope, so the hot path is not service-to-service at all. `@erp/contracts` already gives shared types. Revisit only if profiling shows a synchronous call is the bottleneck |

---

## Phase 0 — Planning & Design (1–2 weeks)
- [x] ~~Finalize tenancy model~~ → **shared DB + `tenant_id`, hybrid-ready**
- [x] ~~Define first module~~ → **HR first, second module immediately after**
- [?] **Decide which module is second** — it determines what the plugin contract must generalise over
- [?] **OWNER: confirm HR feature granularity** — is `employee` / `leave` / `attendance` /
      `payroll` the right set of separately sellable units?
- [?] **OWNER: who assigns features to packs, and who sets prices?** Recurring decisions,
      separate permissions — someone must own each
- [?] **OWNER: do pack changes reach existing subscriptions or only new ones?**
      If "only new", **packs need versioning** and subscriptions pin to the version bought —
      a schema decision that must be made before Phase 4
- [?] Define MVP pack tiers and pricing (Starter / Growth / Enterprise)
- [x] ~~Design domain model~~ → see documentation §5 (incl. `isolation_mode`, tenant status)
- [x] ~~Choose tech stack~~ → **Angular + NestJS + PostgreSQL**
- [x] ~~Confirm API style~~ → **REST over HTTP/JSON** for internal service-to-service calls
- [?] Choose payment provider (e.g. Stripe) and confirm regional compliance needs
- [x] ~~Draft high-level architecture diagram~~ → see `architecture.mermaid`
- [?] **Decide: is read-only a third entitlement state?** (downgraded clients view but
      cannot create). Model as a third state now, or not at all — avoid bolting on later.
- [?] **Confirm statutory retention rules** for financial records (Tunisian + EU) with a
      qualified lawyer; this shapes the hard-delete design

## Phase 1 — Kubernetes Infrastructure Foundation (2–3 weeks)
- [ ] Provision Kubernetes cluster (managed: EKS/GKE/AKS, or self-managed)
- [ ] Set up namespaces per environment (dev/staging/prod)
- [ ] Install ingress controller + cert-manager, configure TLS
- [ ] Set up GitOps pipeline (ArgoCD/Flux) and Helm chart structure
- [ ] Set up CI pipelines (build, test, image push) per service
- [ ] Deploy PostgreSQL (operator or managed service)
- [ ] **Deploy PgBouncer** for connection pooling
- [ ] **Deploy Redis (HA)** — backs per-request entitlement lookups
- [ ] Deploy message broker (Kafka/RabbitMQ)
- [ ] Set up observability stack: Prometheus/Grafana, Loki/ELK, Jaeger/Tempo
- [ ] Configure secrets management (Sealed Secrets or Vault)

## Phase 2 — Identity & Access (Keycloak) (2 weeks)
> **Scope guard:** Keycloak is a pure IdP. If a task here mentions packs, subscriptions
> or module entitlements, it belongs in Phase 3, not here.

- [ ] Deploy Keycloak (HA) with dedicated PostgreSQL backing store
- [x] ~~Design realm strategy~~ → **single shared realm, tenant = Keycloak group**
- [ ] Configure clients: SPA (public, PKCE), backend services (confidential)
- [ ] Define roles: global (super-admin, support) and tenant-level roles
- [ ] Configure token claims: **`tenant_id` and platform roles ONLY** — no `active_modules`,
      no `pack_id`, no tenant-defined roles, no permission lists
- [ ] Set `tenant_id` as a **group attribute**, not per-user (per-user attributes drift)
- [ ] **Reject tokens with missing/empty `tenant_id` at the gateway** (fail closed)
- [ ] Define **platform roles**: `super-admin`, `product-admin`, `pricing-admin`, `support`,
      `support-write` — feature-assignment separate from price-setting
- [ ] Enforce the invariant: **a user never holds both `tenant_id` and a platform role**,
      at provisioning AND validated at the gateway
- [ ] Separate Keycloak **groups for staff** with MFA enforced at group level
- [ ] Separate **OAuth clients** for admin portal vs tenant portal — distinct redirect URIs,
      shorter session timeout on admin
- [ ] Implement token validation middleware in API Gateway, verifying against
      **locally cached JWKS public keys** (no per-request call to Keycloak)
- [ ] Automate tenant group + first `tenant-admin` user provisioning on signup
- [ ] (Optional) Set up LDAP/AD federation for enterprise tenants

## Phase 3 — Data Layer Foundations (2 weeks) — **DO BEFORE Phase 4**

Everything here is what makes the hybrid additive later instead of a rewrite. Retrofitting
any of it onto a live system is significantly harder.

- [ ] **Build the tenant resolution layer** — reads `tenant_id` from request context,
      branches on `Tenant.isolation_mode`, returns connection. Only the `shared` branch is
      implemented; the `dedicated` branch is a stub. All data access goes through this.
- [ ] **Enable PostgreSQL Row-Level Security** on every tenant-scoped table
- [ ] Set `app.tenant_id` session variable on connection checkout
- [ ] Add `isolation_mode` to the Tenant model (always `shared` at launch)
- [ ] Enforce schema rules: `tenant_id` directly on every tenant-scoped table (never
      join-derived); surrogate PK + separately indexed `tenant_id` (**not** a composite PK)
- [ ] **Write automated cross-tenant access tests** — attempt to read another tenant's
      data and assert failure. Run in CI on every commit.
- [ ] Build **table enumeration from schema metadata** (never a hardcoded list) — reused by
      export, hard delete, and future tenant migration
- [ ] Create the RBAC schema: `Role (UNIQUE tenant_id, name)`, `RolePermission`, `UserRole (scope)`
- [ ] Create the catalog schema: `Feature (status)`, `PackFeature`, `FeaturePrerequisite`,
      `PackChangeAudit`
- [ ] **Design the admin data path deliberately** — platform users have no `tenant_id`, so
      RLS denies by default. Admin queries set tenant context explicitly and log every
      access. This is the most likely future cross-tenant leak; do not let it grow ad hoc
- [ ] **Lock the permission naming convention** `module.resource.action` — inconsistent
      formats registered by modules can never be fully cleaned up afterwards

## Phase 4 — Core Platform Services (3–4 weeks)
- [ ] Build Tenant Service (CRUD, lifecycle states, provisioning orchestration)
- [ ] Build Catalog Service (Modules, Features, versioning)
- [ ] Build Pack Service (Pack definitions, pricing, module bundling)
- [ ] Build Subscription Service (tenant↔pack link, upgrade/downgrade, proration logic)
- [ ] **Implement gateway entitlement resolution**: one Redis read per request, fallback to
      Subscription Service on miss, forward result as trusted request context
- [ ] **Implement service-level re-check from context** (defense in depth) —
      **absent context = deny**, never assume allowed
- [ ] **Implement event-driven Redis invalidation** on subscription change (TTL is the
      safety net, not the mechanism)
- [ ] **Add entitlement check to the job scheduler** — background jobs bypass the gateway,
      so a disabled module will otherwise keep running recurring reports/invoices
- [ ] Build the **permission resolution layer**: user → tenant roles → effective permissions,
      cached in Redis alongside entitlements
- [ ] Build the **NestJS `@RequirePermission` guard** (declarative, checks permissions never roles)
- [ ] Implement **scope enforcement in the query layer** (`self`/`department`/`tenant`),
      applied alongside the RLS tenant filter
- [ ] Build tenant custom-role management (create/edit roles from the permission list)
- [ ] Seed default system roles per module (`is_system: true`)
- [ ] Keep `tenant-admin` a **platform** role — it must NOT implicitly grant module
      permissions such as `hr.payroll.read`
- [ ] Build **feature-level entitlement** (not module-level): Redis caches the active
      feature set; routes declare `@RequireFeature`
- [ ] Build the **manifest migration step**: syncs module manifests into Catalog, validates
      feature prerequisites at deploy time, marks removed features deprecated (never deletes)
- [ ] Build **pack composition validation** against feature prerequisites — reject an
      invalid pack at configuration time, not at subscription
- [ ] Build admin-portal **feature-to-pack assignment** — new features entitled to nobody
      until explicitly assigned (a human business decision)
- [ ] Build **impact preview** before committing a pack change ("this affects 47 tenants")
- [ ] Build **`PackChangeAudit`** — who, when, before/after state, tenants affected
- [ ] Make **feature removal from a pack a higher-privilege operation** than addition
- [ ] Build the **unassigned-features view** in the admin portal ("registered but in no pack")
- [ ] Build `GET /api/me/navigation` — entitlement ∩ permissions. Not-entitled returns
      `status: locked` (greyed + upgrade prompt); no-permission omits the item entirely
- [ ] **Audit-log permission-denied events**, not only successes
- [ ] Wire up event publishing for tenant/subscription lifecycle changes
- [ ] Implement soft-lock on module downgrade (entitlement layer only — **never touch data**)
- [ ] Implement staged tenant lifecycle: `active → suspended → soft_deleted → hard_delete`
- [ ] **Build per-tenant export early** — it is the paid dump feature, the GDPR deletion
      evidence, AND the future dedicated-DB migration script, all in one
- [ ] Auto-trigger export at soft-delete and email the client the link
- [ ] Implement hard delete: metadata-driven table enumeration, FK dependency order,
      in a transaction, verifying zero remaining rows before commit

## Phase 5 — Billing & Payments (2–3 weeks)
- [ ] Integrate payment provider SDK (e.g. Stripe Billing)
- [ ] Build Billing Service: invoice generation, payment status tracking
- [ ] Implement webhook handlers (`invoice.paid`, `payment_failed`, `subscription.updated`)
- [ ] Handle proration on plan changes
- [ ] Build dunning/retry logic for failed payments
- [ ] (Optional) Usage-based/metered billing support

## Phase 6 — ERP Modules: HR first (parallel, ongoing)
- [ ] **Define the module plugin contract BEFORE writing HR** — feature/permission
      registration (using the locked naming convention), default system role declaration,
      navigation item declaration with required permissions, route entitlement declaration,
      export hooks, scheduled-job module ownership, migration plug-in points
- [ ] Build **HR module** against that contract: employee records, org structure,
      leave management, time & attendance
- [ ] Implement HR **relationship-based checks** — approval chains and self-access
      exceptions derived from org structure, NOT expressible as roles
- [ ] **Payroll deferred** — most locale-specific, largest scope risk for MVP
- [ ] Build the **second module** immediately after — this is what proves the plugin
      contract, entitlement checks and pack model actually generalise
- [ ] Ensure modules respect tenant isolation and entitlement checks
- [ ] Ensure every module's data access goes through the tenant resolution layer

## Phase 7 — Portals (Frontend) (3–4 weeks)
- [ ] Tenant Portal: signup, subscription management, user management, billing history
- [ ] Admin Portal: manage tenants, packs, modules, pricing, support tools
- [ ] SSO login flow integrated with Keycloak (Authorization Code + PKCE)

## Phase 8 — Testing & Hardening (2 weeks)
- [ ] End-to-end tests for signup → provisioning → subscription → billing flows
- [ ] Load testing for API Gateway and core services
- [ ] Security review: mTLS between services, secrets audit, dependency scanning
- [ ] Tenant isolation testing (cross-tenant data leakage checks — should already be in CI)
- [ ] **Verify entitlement fails closed**: call a service directly, bypassing the gateway,
      and assert denial
- [ ] **Verify permission enforcement is server-side**: call an endpoint whose menu item is
      hidden and assert denial (the menu is a UX affordance, not a security boundary)
- [ ] Verify two tenants can create identically-named roles with different permission sets
- [ ] Verify custom roles survive a soft-lock/re-upgrade cycle untouched
- [ ] Verify a token carrying both `tenant_id` and a platform role is rejected
- [ ] Verify a newly registered feature is entitled to nobody until assigned to a pack
- [ ] Verify a pack violating feature prerequisites is rejected at creation
- [ ] Verify admin access to tenant data is logged and cannot bypass RLS implicitly
- [ ] **Verify background jobs stop** for a soft-locked module
- [ ] Test full downgrade → re-upgrade cycle, asserting data is intact
- [ ] Test staged deletion: suspend → soft-delete → export generated → hard delete verified
- [ ] GDPR readiness: data export/delete per tenant

## Phase 9 — Launch & Operations
- [ ] Production cutover, DNS/TLS finalization
- [ ] Set up alerting rules (Prometheus Alertmanager)
- [ ] On-call runbook for incident response
- [ ] Post-launch monitoring of billing/provisioning pipelines

---

### Suggested team allocation (if multiple people)
- **Platform/DevOps:** Phase 1, ongoing infra maintenance
- **Identity/Backend:** Phase 2, Phase 3 (data layer), Phase 4
- **Payments/Backend:** Phase 5
- **Frontend (Angular):** Phase 7
- **Module developers:** Phase 6 — HR first, then the second module

### Deferred by design — build only on a real trigger
- **Dedicated-database tier.** Triggers: a contract requiring physical isolation, a client
  causing noisy-neighbour problems, or an enterprise tier launch. Build against one real
  client, not speculatively. Work needed: provisioning automation, per-DB migration
  orchestration, migration script (reuses the export machinery from Phase 4).
- **In-process entitlement cache** on top of Redis. Trigger: profiling shows the single
  Redis read is a bottleneck.
- **Read-only entitlement state.** Decide in Phase 0 — model it as a third state or skip it.
