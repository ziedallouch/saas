# ERP SaaS Platform — Project Documentation

## 0. Technology Stack (DECIDED)

| Layer | Choice | Note |
|---|---|---|
| Frontend | **Angular** | Strong forms handling (HR is form-heavy), built-in i18n, scales across a team |
| Backend | **NestJS** (Node/TypeScript) | DI + modular structure; guards map directly onto entitlement checks; mature job scheduling; shares Angular's conventions |
| Database | **PostgreSQL** | Best-in-class Row-Level Security — core to the isolation design |
| Identity | **Keycloak** | OIDC/OAuth2, SSO, optional LDAP federation later |
| Cache | **Redis** | Per-request entitlement lookups at the gateway |
| Runtime | **Kubernetes** | Per-service scaling, GitOps deployment, environment parity |

> **Next.js was considered and rejected.** It is a React *frontend* framework; its backend
> capabilities exist to serve a React frontend. With an Angular frontend it would run purely
> as an API server — losing what makes it valuable while lacking the DI, guards/interceptors,
> and background job scheduling an ERP backend needs. NestJS provides these natively.

**First module: HR**, with a second module following immediately after. See §10.

---

## 1. Vision

A **multi-tenant ERP delivered as a service (SaaS)**. Each client (tenant) subscribes to a
**pack** (bundle of modules/features) and can upgrade, downgrade, or customize their
subscription over time. The platform is built as a set of containerized microservices
deployed on **Kubernetes**, with **Keycloak** as the central identity provider.

Core pillars:
- **Tenant management** — onboarding, lifecycle, isolation
- **Module & feature catalog** — what capabilities exist and how they're entitled (**HR first**)
- **Packs & subscriptions** — commercial bundles built from modules/features
- **Billing & payment** — recurring billing, invoicing, payment provider integration
- **Identity & access** — SSO, RBAC, multi-tenant auth via Keycloak
- **Infrastructure** — Kubernetes-based, scalable, observable, GitOps-driven

---

## 2. High-Level Architecture

- **Pattern:** Microservices behind an API Gateway, event-driven where useful (subscription
  changes, provisioning, billing events).
- **Multi-tenancy model (DECIDED): hybrid, starting shared.**
  All tenants begin on a **shared database with a `tenant_id` column**, protected by
  PostgreSQL Row-Level Security. A **tenant resolution layer** and an `isolation_mode`
  field exist from day one so a **dedicated database** can be offered later (enterprise
  tier) without rewriting data access. See §5.
- **Identity (DECIDED):** Keycloak issues OIDC/OAuth2 tokens carrying **only `tenant_id`
  and roles**. Keycloak holds no knowledge of packs, subscriptions, or module
  entitlements — those are resolved separately at the gateway. See §3 and §4.
- **Communication:** REST/gRPC for synchronous calls, a message broker (Kafka or RabbitMQ)
  for asynchronous events (e.g. `subscription.upgraded`, `tenant.provisioned`,
  `payment.failed`).

### Core services

| Service | Responsibility |
|---|---|
| API Gateway / BFF | Routing, JWT validation, **entitlement resolution (Redis)**, rate limiting |
| Identity (Keycloak) | Authentication, SSO, tenant groups, roles — **no entitlement data** |
| Entitlement Cache (Redis) | Per-tenant active module set, event-invalidated, TTL as safety net |
| Tenant Service | Tenant lifecycle: create, suspend, delete, provisioning orchestration |
| Catalog Service | Registry of Modules → Features → Permissions |
| Pack Service | Packs = bundles of modules/features + pricing tiers |
| Subscription Service | Tenant ↔ Pack link, upgrade/downgrade, proration, trials |
| Billing Service | Invoicing, payment provider integration (Stripe recommended), webhooks |
| Notification Service | Emails/webhooks for billing, provisioning, alerts |
| ERP Core Modules | Pluggable business modules (Accounting, HR, Inventory, CRM, …) |
| Admin Portal | Super-admin: manage clients, packs, modules, pricing |
| Tenant Portal | Self-service: manage subscription, users, billing |

---

## 3. Identity & Authorization (Keycloak)

> **Design principle (DECIDED):** Keycloak is a *pure identity provider*. It answers
> "who is this user, which tenant do they belong to, what roles do they hold" — nothing
> more. Packs, subscriptions and module entitlements are **business data** owned by the
> Subscription Service and never synced into Keycloak. This keeps the identity layer
> decoupled from the commercial domain, which changes on a completely different cadence.

**Realm strategy (DECIDED):** Single shared realm. Tenants are represented as Keycloak
**groups**, with `tenant_id` as a **group attribute** (not a per-user attribute — per-user
attributes drift, and a user created without one produces a token with no tenant).

*Why groups over realm-per-tenant:*

| | Realm-per-tenant | **Group-per-tenant (chosen)** |
|---|---|---|
| Isolation | Hard boundary: separate user stores and signing keys | Logical, via `tenant_id` + group membership |
| Config changes | Applied N times via Admin API automation; no "apply to all realms" primitive | Once |
| Scaling | Each realm carries its own caches/config; strain reported in the hundreds | Tens of thousands of groups |
| Onboarding | Multi-step realm provisioning with partial-failure handling | One Admin API call |
| Cross-tenant support roles | Needs accounts per realm, or an admin realm with token exchange | A plain role |
| Per-tenant SSO federation & login branding | Supported natively | Not available |

Realms buy genuine things — per-tenant Azure AD/LDAP federation, custom login branding,
username collision immunity. But those are **enterprise procurement requirements**, and
realm-per-tenant would reintroduce exactly the per-tenant provisioning overhead that the
shared-database decision (§6) was made to avoid.

**The position mirrors §6 exactly: shared by default, isolated as a premium tier on a real
trigger.** The same enterprise client who demands a dedicated database is usually the one
who wants their own identity federation — so `Tenant.isolation_mode` covers identity as
well as data, not just the database.

*Caveat on the realm-count figures above:* these come from community operational experience
rather than a formal benchmark, and the real ceiling depends on hardware and configuration.
Load-test before ever committing to the realm path at scale.

**Clients:**
- One **confidential client** per backend service (or a shared resource server pattern)
- One **public client** (SPA) for the frontend, using Authorization Code + PKCE

**Roles & claims:**
- **Platform roles only** live in Keycloak: `super-admin`, `support`, `tenant-admin`, `tenant-user`
- Token claims: **`tenant_id` and platform roles only**
- Explicitly **not** in the token: `active_modules`, `pack_id`, subscription state,
  tenant-defined roles, or permission lists
- **Module roles and tenant custom roles live in the application database** — see §10
- A token with a **missing or empty `tenant_id` must be rejected at the gateway** (same
  fail-closed rule as entitlements)

**Why entitlements are not in the token.** Two approaches were considered:

| | Sync into Keycloak (rejected) | Resolve at gateway (**chosen**) |
|---|---|---|
| Mechanism | Subscription Service calls Keycloak Admin API on every plan change; protocol mapper injects claim | Gateway queries Redis-cached entitlement set per request |
| Propagation delay | Until the user's token refreshes | Seconds (cache invalidation) |
| Coupling | Identity layer coupled to billing domain | Clean separation |
| Failure mode | Stale token grants access to a dropped module | Fails closed |

**Other:**
- SSO across all ERP modules under one login
- Optional user federation (LDAP/AD) for enterprise clients
- Keycloak deployed HA (≥2 replicas) backed by PostgreSQL, behind the same ingress/TLS setup as the rest of the platform
- The gateway caches Keycloak's **JWKS public keys** and verifies token signatures locally —
  token validation requires no network call to Keycloak per request

**Other:**
- SSO across all ERP modules under one login
- Optional user federation (LDAP/AD) for enterprise clients
- Keycloak deployed HA (≥2 replicas) backed by PostgreSQL, behind the same ingress/TLS setup as the rest of the platform

---

## 4. Kubernetes Infrastructure

- **Namespaces:** per environment (`dev`, `staging`, `prod`); optionally per-tenant namespace for isolation-heavy enterprise clients
- **Ingress:** NGINX or Traefik + `cert-manager` for automated TLS (Let's Encrypt)
- **Service mesh (optional):** Istio/Linkerd for mTLS, traffic policies, observability
- **Databases:** PostgreSQL — either self-managed via Operator/StatefulSet, or an external managed service (RDS/Cloud SQL) for production
- **Messaging:** Kafka or RabbitMQ, deployed via Helm/Operator
- **Cache:** Redis (HA) — backs the per-request entitlement lookup at the gateway
- **Connection pooling:** PgBouncer in front of PostgreSQL (needed now, essential once
  dedicated-DB tenants are introduced)
- **Config & secrets:** ConfigMaps for non-sensitive config, Sealed Secrets or HashiCorp Vault for secrets
- **CI/CD:** GitOps with ArgoCD or Flux, Helm charts per service, image builds via GitHub Actions/GitLab CI
- **Observability:**
  - Metrics: Prometheus + Grafana
  - Logs: Loki or the ELK stack
  - Tracing: Jaeger or Tempo
- **Scaling:** Horizontal Pod Autoscaler per service, Cluster Autoscaler at the node pool level
- **Storage:** PersistentVolumeClaims for stateful workloads (Postgres, Keycloak, message broker)

---

## 5. Domain Model (key entities)

```
Tenant (id, name, status, tier, isolation_mode, created_at, deleted_at)
         status:         active | suspended | soft_deleted
         isolation_mode: shared | dedicated      -- always 'shared' at launch
User (id, tenant_id, keycloak_id, email)
Role (id, tenant_id, name, is_system)          -- UNIQUE (tenant_id, name)
RolePermission (role_id, permission_code)      -- permission_code = module.resource.action
UserRole (user_id, role_id, scope)             -- scope: self | department | tenant
Module (id, code, name, version, description)
Pack (id, name, price, billing_cycle)
PackFeature (pack_id, feature_id)              -- features are the unit sold, see §7
Feature (id, module_id, code, name, status)    -- status: active | deprecated
FeaturePrerequisite (feature_id, requires_feature_id)
PackChangeAudit (id, actor_id, pack_id, action, before, after, tenants_affected, at)
Subscription (id, tenant_id, pack_id, status, start_date, renewal_date)
Invoice (id, tenant_id, subscription_id, amount, status, due_date)
Payment (id, invoice_id, provider_ref, status, paid_at)
```

Relationships: a **Tenant** has one active **Subscription** to a **Pack**; a **Pack**
bundles multiple **Modules**, each with a set of **Features**; **Invoices** are generated
per billing cycle from the Subscription and settled via **Payments**.

**Schema rules (important for future migration to dedicated DBs):**
- Every tenant-scoped table carries `tenant_id` **directly** — never derivable only
  through multiple joins. This is what makes per-tenant extraction a script rather than
  an archaeology project.
- Use a **surrogate primary key + separately indexed `tenant_id`**, not a composite PK
  including `tenant_id`. IDs then need no rewriting when a tenant is migrated to a
  dedicated database.
- `tenant_id` is included in indexes wherever query patterns require it.

---

## 6. Data Layer & Tenant Isolation (DECIDED)

### Chosen model: hybrid, launching shared

All tenants launch on **one shared PostgreSQL database, shared schema, `tenant_id` column**.

**Why shared first**, given the initial target of small enterprises:
- Per-database baseline cost (connections, memory, backup slots, monitoring) is roughly
  fixed regardless of tenant size — small clients on dedicated DBs are disproportionately expensive
- Onboarding is an `INSERT`, not a provision-plus-migrate cycle: signup stays instant
- One migration to run instead of N, which matters most while the schema is still volatile
- Small enterprises do not ask for what dedicated DBs buy (data residency clauses,
  contractual isolation, per-client PITR) — those requests come from enterprise procurement

**Dedicated databases remain on the roadmap** as a premium/enterprise tier offering
stronger isolation, per-client point-in-time restore, and noisy-neighbour containment.

### Built from day one to enable the dedicated path

These five items are non-negotiable at launch — they are what make the hybrid additive
later rather than a rewrite:

1. **Tenant resolution layer.** All data access goes through a component that reads
   `tenant_id` from request context and returns a connection/session. Today it always
   returns the shared pool. Later it branches on `Tenant.isolation_mode` and returns a
   dedicated connection instead — with no changes to business code.
2. **PostgreSQL Row-Level Security, enabled now.** `app.tenant_id` is set as a session
   variable on connection checkout; RLS policies scope every tenant-owned table
   automatically. Retrofitting RLS onto a live system is far harder than starting with it.
3. **`isolation_mode` on the Tenant record**, even though every value is `shared` at
   launch. Having the field and the branch exist from the start makes the second path additive.
4. **Extraction-friendly schema** — see the schema rules in §5.
5. **Per-tenant export**, built early. It is simultaneously the paid dump feature, the
   GDPR deletion evidence, and the migration script for moving a client to a dedicated DB.

> **Note on the security argument.** Dedicated DBs eliminate the "forgot the `WHERE
> tenant_id`" bug class, but *not* tenant confusion — if the resolution layer returns the
> wrong connection, data leaks just as badly, and that bug is harder to catch because it
> lives in infrastructure code. Properly configured RLS closes most of the shared-schema
> gap. Treat isolation as a meaningful bonus, not the deciding factor. **Write automated
> cross-tenant access tests regardless of model.**

### Triggers to introduce the dedicated path

Build it against a real client, not speculatively. Concrete signals:
- A prospect's contract requires physical isolation and the deal justifies the work
- A client outgrows shared resources and causes noisy-neighbour problems
- An enterprise tier launches with isolation as a headline differentiator

---

## 7. Packs, Modules & Entitlements (DECIDED)

- A **Module** is a business capability (e.g. "Inventory", "HR", "Accounting").
- A **Feature** is a granular capability inside a module (e.g. "Payroll").
- A **Pack** is a commercial bundle: a named set of features at a price point
  (e.g. Starter, Growth, Enterprise), plus optional custom/à-la-carte packs.

### Three levels, not two

```
hr                  → MODULE      entitlement, coarse
hr.payroll          → FEATURE     entitlement, the actual unit sold
hr.payroll.read     → PERMISSION  user authorization (§10)
```

> **Features answer "did they pay for it?" Permissions answer "are they allowed to do it?"**
> Both can exist for the same thing, and both must pass. A Growth tenant owns Payroll, but
> only the HR manager should see salaries.

### Features are the entitlement unit (DECIDED)

Packs may include HR **with or without** Payroll, so entitlement is resolved at **feature**
granularity, not module. A module counts as active if any of its features are.

- Redis caches the tenant's active **feature set**, e.g.
  `["hr.employee", "hr.leave", "hr.attendance"]` — plus `"hr.payroll"` on Growth
- Routes declare the feature they require: `@RequireFeature('hr.payroll')`
- `PackFeature` rows are first-class, so pricing and packaging reference features directly

**Initial HR feature set:**

| Feature | Scope |
|---|---|
| `hr.employee` | Core records, org structure |
| `hr.leave` | Requests, approvals, balances |
| `hr.attendance` | Time tracking |
| `hr.payroll` | Deferred from MVP, but registered |

**Granularity rule:** resist going finer (`hr.employee.documents` as its own feature) until
a real pricing need appears. A feature can always be split later; **merging two that have
already been sold separately means migrating live subscriptions.**

**Features declare prerequisites.** `hr.payroll` requires `hr.employee` — payroll is
meaningless without the employee records it runs against. Prerequisites are declared in the
plugin contract and **pack composition is validated against them at configuration time**,
so an invalid pack is rejected when created rather than discovered when a client subscribes.

### Resolution mechanism

Entitlements are resolved **at the API Gateway, per request, from Redis** — never from
the token (see §3 for why).

- Gateway performs **one Redis read per request** for the tenant's active feature set,
  falling back to the Subscription Service on cache miss
- The resolved set is forwarded downstream as **trusted request context** — services do
  **not** issue a second Redis call
- Services re-check the module against that context (**defense in depth**)
- **Absent entitlement context = deny.** Never "assume allowed." This is what protects
  routes reachable without traversing the gateway: internal service-to-service calls,
  misconfigured network policies, newly added unregistered routes

**No in-process cache layer at launch.** A short-lived local cache on top of Redis was
considered and deliberately deferred — one Redis read per request is cheap, and premature
cache layering makes invalidation bugs much harder to reason about. Add only if profiling
justifies it.

### Cache invalidation

Subscription changes **publish an event that actively busts the tenant's Redis key**.
The TTL (30–60s) is the safety net, not the primary mechanism.

### Background jobs

Scheduled work (recurring invoices, sync jobs, reports) does **not** traverse the API
gateway, so the entitlement check above will not catch it. **The scheduler must check
feature entitlement before dispatching any job.** Otherwise a disabled Accounting module
will keep emailing monthly reports.

---

## 7b. Feature Registration (DECIDED)

### Declarative manifest + migration

Each module ships a **versioned manifest file in its repository**. A migration step in the
deploy pipeline syncs it into the Catalog Service — the same mental model as database
migrations.

```
{ module: 'hr',
  features: [
    { code: 'hr.employee', name: 'Employee Records', requires: [] },
    { code: 'hr.payroll',  name: 'Payroll',          requires: ['hr.employee'] }
  ],
  permissions: ['hr.employee.read', 'hr.employee.write', ...],
  navigation:  [...] }
```

**Runtime self-registration was rejected.** Feature codes are *pricing units*: a new feature
is a commercial object that must be assigned to packs and possibly priced. That must not
happen as an invisible side effect of a deploy. With a manifest file, adding `hr.payroll`
appears in a pull request where someone can ask which packs include it — and it is
versioned, reviewable, replayable, and rolls back with the release.

### New features are inert until priced

**A newly registered feature is entitled to no one.** It exists in Catalog; no tenant can
use it until an admin explicitly adds it to a pack.

1. Developer adds the feature to the manifest → PR review
2. Deploy → migration registers it in Catalog, entitled to nobody
3. **Admin assigns it to packs in the admin portal — a business decision, made by a human**
4. Affected tenants' Redis keys are busted → entitlement goes live

The alternative (new features flowing automatically into existing packs) lets a developer
silently grant every client a capability you may have intended to charge for. Step 3 is
deliberately manual.

### Registration rules

- **Validate prerequisites at migration time.** If `hr.payroll` declares
  `requires: ['hr.employee']` and that feature does not exist, the migration fails. Catch it
  at deploy, not at subscription.
- **Never hard-delete a feature.** Removal from a manifest marks it **deprecated**. Active
  subscriptions may reference it and historical invoices certainly do — deletion breaks
  billing history.
- **Flag unassigned features in the admin portal.** A "registered but in no pack" list makes
  it obvious when something shipped but was never priced, so features do not quietly
  accumulate that nobody can buy.

---

## 8. End-to-End Workflow (DECIDED)

### Provisioning path — once per client

1. **Client subscribes to a Pack.** Creates a `Tenant` (`isolation_mode: shared`) and a
   `Subscription` linking tenant → pack.
2. **Tenant Service provisions.** Creates a Keycloak **group** for the tenant and a first
   `tenant-admin` user with the `tenant_id` attribute. **No database provisioning** — the
   tenant simply begins writing rows carrying its `tenant_id`, so onboarding is near-instant.
3. **Tenant-admin invites users.** Each becomes a `User` row scoped to `tenant_id`, plus a
   Keycloak account in the tenant's group with roles assigned.

### Request path — every request

4. **User logs in** via the SPA against Keycloak (Authorization Code + PKCE).
5. **Keycloak issues a token containing `tenant_id` and `roles` only.**
6. **Gateway validates the token** locally against cached JWKS public keys (no network
   call to Keycloak), and establishes tenant/role context.
7. **Gateway resolves entitlements** from Redis and rejects immediately if the target
   module is not in the tenant's active set.
8. **Request reaches the service.** The tenant resolution layer reads `tenant_id` from
   context, checks `isolation_mode`, returns a shared-pool connection, and sets the
   `app.tenant_id` session variable on it.
9. **RLS enforces isolation at the database level**, independent of whether application
   code remembered its `WHERE` clause.
10. **Service re-checks module entitlement** from request context (defense in depth).
11. **NestJS guard checks the required permission** (`@RequirePermission(...)`), resolved
    from the user's tenant-scoped roles — cached in Redis alongside entitlements (§10).
12. **Scope is applied in the query layer** (`self` / `department` / `tenant`), alongside
    the RLS tenant filter — it determines which rows, not which actions.

**Per-request cost:** one Redis read at the edge for entitlements; one cached lookup for the
user's effective permissions. No network call to Keycloak.

**Both layers must pass.** Entitlement failure and permission failure are independent:
a tenant may own HR while this user cannot read payroll.

---

## 9. Lifecycle: Downgrade, Suspension & Deletion (DECIDED)

### Module downgrade — soft-lock, never purge

- **Data is never touched.** Rows stay exactly as they are; no flags on individual records
- The gate lives **entirely in the entitlement layer** — the module's API routes are
  rejected and the UI hides or greys out the module
- **Re-upgrade is instant**: the module reappears in the active set with all data intact
- Background jobs for the disabled module **stop** (see §7)

The commercial argument matters as much as the technical one: a client who downgrades
seasonally and returns finds their data intact, making re-subscription frictionless.
Purging would make every downgrade a permanent loss and a support burden.

*Open option:* a **read-only** middle tier (view historical data, cannot create new
records). Nicer experience, weaker upsell lever. If wanted, model it as a **third
entitlement state** rather than bolting it on later.

### Tenant deletion — staged, never immediate

| Stage | Trigger | Effect | Reversible |
|---|---|---|---|
| **Suspended** | Non-payment, 7–14 days after failed invoice | Access blocked, data intact, background jobs stopped | Yes — immediately on payment |
| **Soft-deleted** | Explicit cancellation, 30–90 day grace period | Excluded from all queries, users cannot log in, data still present | Yes |
| **Hard-deleted** | Grace period expires, or explicit request | Rows removed; Keycloak group and users deleted | No |

Most "deletions" in practice never progress past **Suspended**.

**Trigger the export automatically at soft-delete.** Generate the tenant's data dump on
confirmed cancellation, store it, email the link. Same machinery as the paid dump feature,
and it turns the GDPR deletion obligation into something evidenced.

### Hard delete in the shared-DB model

`DELETE FROM ... WHERE tenant_id = ?` across every tenant-scoped table in foreign-key
dependency order. Two rules make this safe:

- **Generate the table list from schema metadata, never a hardcoded array.** A hardcoded
  list silently goes stale the moment someone adds a table, and the gap surfaces only at audit.
- **Run in a transaction and verify zero remaining rows for that `tenant_id` before committing.**

This is the exact inverse of the tenant-migration script used to move a client to a
dedicated DB (extract → load → verify → delete). **Same table enumeration logic — build it once.**

### Statutory retention caveat

Accounting and invoicing data often carries statutory retention requirements (commonly
7–10 years for financial records in many jurisdictions). This obligation may sit with the
client while the data sits with the platform, and **GDPR erasure rights do not override
statutory retention obligations** — these can genuinely conflict.

Common pattern: hard-delete operational data, retain the minimum required financial
records in a separate retention store, and document this in the contract and privacy
policy. **This is a description of common practice, not legal advice** — confirm the
specifics against Tunisian and EU rules and against the client contracts with a qualified
lawyer before finalising.

---

## 10. Application Authorization: RBAC (DECIDED)

> **Two independent layers, both must pass.**
> **Entitlement** (§7) answers *"does this tenant's pack include HR?"* — commercial.
> **Permission** (this section) answers *"can this user approve a leave request?"* — identity.
> A tenant can own HR while a given user still cannot touch payroll data.

### Model: RBAC with scoping (not ABAC)

Full attribute-based access control was rejected — flexible but slow to reason about and
hard to debug. Role-based with structural scopes covers nearly everything in an ERP;
narrow exceptions are handled explicitly where genuinely needed.

**Layer 1 — Permissions.** The atomic unit, always `module.resource.action`:

```
hr.employee.read      hr.leave.approve
hr.employee.write     hr.payroll.read
hr.employee.delete    hr.attendance.write
```

Defined by the module itself and registered into the Catalog via the plugin contract —
which is why that contract must exist before HR is written. **The naming convention is
fixed before the first module ships**; inconsistent formats registered by modules can never
be fully cleaned up afterwards.

**Layer 2 — Roles.** Named bundles of permissions, per module:

```
hr-viewer   → hr.employee.read, hr.attendance.read
hr-officer  → + hr.employee.write, hr.leave.approve
hr-manager  → + hr.payroll.read, hr.employee.delete
```

> **Users get roles; code checks permissions.** Never check roles directly in business
> logic — `if (user.role === 'hr-manager')` hardcodes a policy decision that must stay
> configurable.

**Layer 3 — Scope.** *Which records*, not which actions:

```
self        → own records only
department  → their department's records
tenant      → everything in the tenant
```

A manager and an employee may both hold `hr.leave.read`; the difference is whose leave they
see. Without this layer roles duplicate combinatorially (`hr-viewer-own`, `hr-viewer-dept`)
and become unmanageable.

### Where each check happens

| Concern | Location |
|---|---|
| Platform role assignment | Keycloak token (`super-admin`, `support`, `tenant-admin`, `tenant-user`) |
| Tenant-scoped roles & permissions | Application DB, resolved server-side, cached in Redis alongside entitlements |
| Permission enforcement | NestJS guard, declaratively: `@RequirePermission('hr.leave.approve')` |
| Scope enforcement | **Query layer**, alongside the RLS tenant filter — it filters rows, not actions |

**Permissions are never put in the token.** They bloat it and go stale on every role change —
the same failure mode rejected for entitlements in §3.

### Tenant-defined custom roles

Tenants create and manage their own roles. **These are stored in the application database,
never in Keycloak.**

```
Role (id, tenant_id, name, is_system, created_at)
    UNIQUE (tenant_id, name)
RolePermission (role_id, permission_code)
UserRole (user_id, role_id)
```

**Why not Keycloak:**
- **Volume** — hundreds of tenants × several roles each = thousands of realm roles in a flat
  namespace; a configuration surface Keycloak is not built to carry
- **Wrong ownership** — a tenant admin editing a role would trigger a Keycloak Admin API
  write, granting the application config-write access to the IdP for routine business operations
- **Staleness** — changes would need to propagate into tokens, reintroducing the sync problem
- **Consistency** — Keycloak answers *who and which tenant*; everything about what a user can
  do is business data

**Name collisions between tenants are structurally impossible.** Uniqueness is
`(tenant_id, name)`, so Tenant A's "Manager" and Tenant B's "Manager" are unrelated rows
with different permission sets. Had roles lived in Keycloak's flat realm namespace, this
would have forced prefixing (`t_a1b2_manager`) — ugly, leaks tenant IDs, and breaks on rename.

**System vs custom roles.** Seed sensible default roles per module (`is_system: true`) so a
new client is usable immediately; `tenant-admin` can then compose custom roles from the
permission list.

**`tenant-admin` is a platform role, distinct from module roles.** It manages users, roles
and subscription — it must **not** implicitly grant `hr.payroll.read`. Separating
"administers the account" from "can see salaries" matters especially in HR.

### Relationship-based checks (HR approval chains)

HR has a pattern roles cannot express: an employee reads their own salary but not a
colleague's; a manager approves their reports' leave but not their own.

These are **relationships derived from org structure**, not roles. They are handled as an
explicit relationship check inside the HR module, querying the org structure table.
Attempting to encode "is this person's manager" as a role does not work.

### Interaction with soft-lock

When a module is soft-locked (§9), tenant custom roles granting its permissions are **left
untouched**. The entitlement check rejects the request regardless; on re-upgrade everything
works again with no repair step. Stripping now-invalid permissions from roles would destroy
tenant configuration that cannot then be restored — same principle as never touching data
on downgrade.

### Auditing

**Log permission-denied events, not only successes.** In HR, repeated failed attempts to
read salary data is a signal worth having.

---

## 11. Application Navigation (DECIDED)

The menu is composed server-side from **both** authorization layers:
- **Entitlement** decides which modules appear at all
- **Permissions** decide which items within a module appear

```
GET /api/me/navigation
→ { modules: [ { code: 'hr', label, status, items: [...] } ] }
```

The backend intersects the tenant's active modules with the user's effective permissions and
returns only what survives both.

**Three rules:**

1. **Menu structure comes from the module, not the frontend.** Each module declares its nav
   items and the permission each requires, via the plugin contract. Adding a module requires
   no Angular changes — the SPA holds no hardcoded menu structure.
2. **The menu is a UX affordance, not a security boundary.** Hiding an item does not protect
   the endpoint. Every route still enforces entitlement and permission server-side.
3. **Not-entitled and no-permission are different states — never collapse them.**

| State | Cause | UI |
|---|---|---|
| `locked` | Tenant's pack lacks the feature | Greyed, with upgrade prompt — a visible upsell |
| *(omitted)* | User lacks the permission | Hidden entirely |

Telling a junior employee "upgrade to see salaries" is wrong on both counts: it is not their
decision to make, and they should not learn that payroll exists. The endpoint returns
`status` for the first case and omits the item entirely for the second.

---

## 11b. Platform-Side Access Control (DECIDED)

This is a **third** authorization concern, distinct from tenant RBAC (§10). It governs
**your own staff in the admin portal** — a different user population from clients working
inside their tenants.

### Platform roles — in Keycloak, not the database

Unlike tenant custom roles, these are few, stable and identity-level, so the reasoning in
§10 that pushed tenant roles into the DB does not apply.

| Role | Scope |
|---|---|
| `super-admin` | Everything, including pricing |
| `product-admin` | Assign features to packs, define packs |
| `pricing-admin` | Set prices on packs |
| `support` | View tenants, assist — no commercial changes |
| `support-write` | Suspend/reactivate tenants — no pricing changes |

> **Feature assignment and price setting are deliberately separate permissions.** Deciding
> that Payroll belongs in the Growth tier is a different decision from deciding what Growth
> costs. Separating them also gives a clean audit story.

### Beyond roles — what pack changes require

**Audit trail, non-negotiable.** Every pack change records who, when, what changed (before
*and* after state), and which tenants were affected. This is the record needed when a client
disputes what they were sold or revenue looks wrong.

**Impact preview before commit.** Adding a feature to Growth affects every Growth tenant
immediately. The admin sees "this affects 47 tenants" *before* confirming.

**Removal is a higher-privilege operation than addition.** Adding a feature is generous and
low-risk; removing one takes away something live clients use and may have paid for. Requires
a separate permission from adding, and should consider a second approver.

---

## 11c. Realm Strategy for Platform vs Tenant Users (DECIDED)

**One realm, separated by roles — not two realms.**

### Why not separate realms

Two realms is trivially manageable (unlike hundreds, §3). The problem is different:
**platform staff need to act on tenant data.** Support views a client's subscription;
product-admin changes a pack affecting live tenants. With separate realms, every such
operation crosses a realm boundary — requiring token exchange, or services accepting two
issuers with two JWKS sets and two claim shapes. That is a permanent complication in every
service's auth layer, for a separation obtainable more simply.

### The token rule

- **Tenant users** carry `tenant_id` + tenant roles
- **Platform users** carry a platform role and **no `tenant_id`**
- A token must have **either** a valid `tenant_id` **or** a platform role. Neither → reject.
- **A user must never hold both.** Enforced at provisioning *and* validated at the gateway —
  a token carrying both is rejected. This is the invariant separate realms would have given
  structurally; here it must be actually checked, not assumed.

### Hardening without a second realm

- **Separate Keycloak groups for staff**, with MFA enforced at group level
- **Separate OAuth clients** for the admin portal and tenant portal — distinct redirect URIs,
  distinct session settings, shorter session timeout on admin
- **Platform actions never reach tenant data through the tenant path.** Support access goes
  through an explicit, audited admin API — never by impersonating a tenant user

### The admin data path — design deliberately

A platform user has no `tenant_id`, so `app.tenant_id` is unset and **RLS denies by default**.
Admin queries must explicitly and deliberately set tenant context, and every such access is
logged.

> **This is the most likely place for a future cross-tenant leak.** Someone builds an admin
> endpoint, RLS is not satisfied, and the quick fix is to bypass RLS entirely. Design this
> path now rather than letting it grow ad hoc.

### Exception

Enterprise tenants demanding their own identity federation get their own realm — the trigger
already defined in §3. That is unrelated to the platform/tenant split and does not change
this decision.

---

## 12. First Module: HR (DECIDED)

**HR ships first; a second module follows immediately after.**

### Why the second module matters from day one

With only one module, packs and entitlements are theoretical — every client gets the same
thing. The **second module is what proves** the plugin contract, the entitlement checks and
the pack model actually hold when modules differ between clients. The architecture is built
for it from the start rather than retrofitted.

### Module plugin contract — define *before* writing HR

HR is the first consumer of this contract, so it must exist first. It specifies:
- How a module registers its features and permissions into the Catalog
  (permission codes follow the fixed `module.resource.action` convention, see §10)
- How it declares its default system roles
- How it declares its navigation items and the permission each requires (see §11)
- How its routes declare the entitlement they require (NestJS guard metadata)
- How it exposes its data to the per-tenant export
- How its scheduled jobs declare module ownership (so they stop on soft-lock, see §7)
- How its migrations plug into the shared schema

### HR MVP scope

| Area | Scope |
|---|---|
| Employee records | Core directory, contracts, documents |
| Org structure | Departments, reporting lines |
| Leave management | Requests, approvals, balances |
| Time & attendance | Basic tracking |
| **Payroll** | **DEFERRED** — the most locale-specific part of HR and the largest scope risk for an MVP |

HR is form-heavy and permission-heavy, making it a good first test of both Angular's forms
layer and the role model. It is also the first consumer of the **relationship-based checks**
described in §10 — approval chains and self-access exceptions derived from org structure.

---

## 13. Billing & Payments

- Recommended provider: **Stripe** (Billing + Webhooks), or a local/regional PSP if needed for market compliance.
- Subscription lifecycle: `trialing → active → past_due → canceled`
- Webhooks drive internal state: `invoice.paid`, `invoice.payment_failed`, `customer.subscription.updated`
- Proration handled on upgrade/downgrade
- Optional usage-based/metered billing for modules priced by consumption (e.g. per-seat, per-transaction)

---

## 14. Open Questions — for the owner

These are **not** decided and block parts of the build. They are a connected set: answering
one without the others leaves the design ambiguous.

1. **HR feature granularity.** Is the four-feature split in §7 (`employee`, `leave`,
   `attendance`, `payroll`) the right set of separately sellable units?
2. **Who decides feature-to-pack assignment, and who sets prices?** A recurring business
   decision, not a one-off. §11b separates the two permissions; someone must own each.
3. **Do pack changes reach existing subscriptions, or only new ones?** If Payroll is added
   to Growth, do current Growth tenants get it, or only tenants subscribing from now on?
   **If the answer is "only new", packs need versioning** and subscriptions must pin to the
   version bought — a schema decision, not a detail.

Also open from earlier phases: whether read-only is a third entitlement state (§9), which
module is second, and the statutory retention review (§9).

---

## 15. Non-Functional Requirements

- **Security:** mTLS between services, secrets vault, regular dependency scanning,
  **PostgreSQL RLS on all tenant-scoped tables**, **automated cross-tenant access tests
  that attempt to read another tenant's data and assert failure**,
  **permission-denied events logged and auditable**
- **Compliance:** GDPR-readiness (data export/delete per tenant), audit logging,
  statutory financial-record retention (see §9)
- **Scalability:** stateless services behind HPA, DB read replicas as needed
- **Availability:** target SLA (e.g. 99.9%), multi-AZ deployment
- **Multi-region (future):** not required for MVP, design data model to not block it later
