# ERP SaaS — Server Architecture

**Status:** draft for review · 2026-09-16
**Scope:** repo topology, shared packages, the trusted context envelope, the end-to-end
request pipeline, fail-closed rules, and database ownership rules.
**Out of scope here:** HR module design (separate document), billing, frontend.

Read alongside `ERP_SaaS_Documentation.md` (architecture), `HANDOFF.md` (reasoning and
rejected alternatives), `Task_Plan.md` (phases).

---

## 0. What this document fixes

| Question | Answer |
|---|---|
| Repo layout | Polyrepo services + **one** shared platform repo publishing versioned packages |
| How services agree on auth state | A signed, versioned **context envelope** minted by the gateway |
| Who owns which tables | **One Postgres schema per service**; migrations touch only the owned schema |
| Where entitlement is decided | Gateway, once per request, from Redis; services re-check from context |
| What happens when anything is missing | **Deny.** Enumerated in §5 |

**Still open, deliberately:** migration tooling (Flyway / Atlas / other) — decided at Phase 3.
Message broker choice. HR sellable feature split.

**Internal transport: decided — REST over HTTP/JSON.** Nothing here is latency-bound; the
hot path is the gateway's single Redis read, not service-to-service. gRPC's proto tooling
and codegen are not worth paying for before profiling says otherwise.

---

## 1. Repo topology

Polyrepo, as preferred. The cost of polyrepo in this architecture is that the
security-critical code must stay identical everywhere; §2 is how that is paid for.

### Platform (one repo, several published packages)

```
erp-platform/
  packages/
    contracts/        → @erp/contracts
    nest-platform/    → @erp/nest-platform
    testing/          → @erp/testing
```

These three are released **together**, as one versioned unit. They are the security
boundary; splitting them into three repos means bumping three versions in lockstep for
every change, which is how skew starts.

### Services (one repo each)

| Repo | Responsibility |
|---|---|
| `erp-gateway` | Token validation, entitlement + permission resolution, context minting, routing |
| `erp-platform-core` | Tenant, Catalog, Pack, Subscription (see note below) |
| `erp-hr-service` | First module |
| `erp-billing-service` | Phase 5 |
| `erp-admin-portal` | Angular — platform staff |
| `erp-tenant-portal` | Angular — tenant users |

> **Note on `erp-platform-core`.** The task plan lists Tenant, Catalog, Pack and
> Subscription as four services. They share tables, always deploy together, and call each
> other on nearly every write. Four deployables here buys nothing at launch and costs four
> pipelines, four charts and four sets of cross-service calls where a function call would
> do. Recommendation: **one deployable, four NestJS modules, four Postgres schemas.** The
> domain boundaries from the design are preserved exactly — only the deployment unit
> changes, and splitting later is a build-config change because the schema boundaries are
> already there. If you disagree, the rest of this document is unaffected.

### Operations

| Repo | Responsibility |
|---|---|
| `erp-dev-environment` | docker-compose, Keycloak realm export, seed data, local run scripts |
| `erp-deploy` | Helm charts, GitOps manifests, per-environment values |
| `erp-ci-templates` | Reusable CI workflows (build, test, image push, isolation tests) |

---

## 2. Shared packages — solving the polyrepo context problem

### 2.1 `@erp/contracts`

Pure TypeScript types + zod schemas. **Zero runtime dependencies.** Anything importable
without pulling in NestJS, a database driver, or a logger.

Contains:
- The context envelope type and its zod schema (§3)
- Event payload schemas (`tenant.provisioned`, `subscription.changed`, `tenant.suspended`, …)
- The module manifest schema
- The API error envelope and error codes
- Permission string format and scope enum

### 2.2 `@erp/nest-platform`

The NestJS runtime. **This is the enforcement code — it exists once and only once.**

- `ErpContextMiddleware` — parse, verify, bind to `AsyncLocalStorage`
- `@RequireFeature()` guard
- `@RequirePermission()` guard
- `TenantConnectionProvider` — the tenant resolution layer
- `TenantSessionInterceptor` — sets `app.tenant_id` per transaction
- `ScopeFilter` — query-layer helper for `self` / `department` / `tenant`
- `AuditLogger` — permission-denied and admin-access events

### 2.3 `@erp/testing`

The cross-tenant isolation harness. Every service imports it and runs it in CI. One
implementation of "try to read another tenant's row and assert failure", so no service
can quietly skip it or write a weaker version.

### 2.4 Distribution

- Private registry: GitHub Packages (least setup if you are on GitHub) or self-hosted Verdaccio.
- Semver, `changesets` for release automation.
- Local development against unreleased packages: `yalc` or `pnpm link`, documented in
  `erp-dev-environment`. Early on the context shape will change weekly — plan for this
  rather than publishing a patch version every twenty minutes.

### 2.5 Skew control

Version skew between services is the failure mode polyrepo introduces. Three defences:

1. **The envelope carries its own version**, independent of the package version (§3.1).
   A service that receives an envelope version it does not understand denies the request.
   This is the defence that actually matters — it does not depend on anyone upgrading.
2. **CI check**: fail the build if a service is more than one minor version behind
   `@erp/nest-platform`.
3. **Renovate/Dependabot** grouped update PRs for the `@erp/*` scope.

---

## 3. The trusted context envelope

The gateway resolves identity, entitlement and permissions once, then forwards the result.
Downstream services never call Keycloak, never call Redis, and never re-resolve.

### 3.1 Transport

```
x-erp-ctx-version: 1
x-erp-ctx:         <base64url(JSON payload)>
x-erp-ctx-sig:     <base64url(HMAC-SHA256(payload, shared secret))>
```

**Why sign it.** Phase 8 requires that calling a service directly, bypassing the gateway,
is denied. Absence of the header covers the naive case; a signature covers the case where
something inside the cluster forges one. The secret comes from the secrets manager and
rotates with a two-key overlap window (accept current and previous, sign with current).

If you later run mTLS + NetworkPolicy and decide the signature is redundant, removing it
is a one-line change. Adding it after services are live is not.

### 3.2 Payload

```ts
interface ErpContext {
  v: 1;
  requestId: string;          // propagated to logs and traces
  issuedAt: number;           // epoch ms
  expiresAt: number;          // issuedAt + 30s — bounds replay if an envelope leaks

  subject: {
    userId: string;           // Keycloak `sub`
    username: string;
  };

  // EXACTLY ONE of the following two is present.
  tenant?: {
    tenantId: string;
    isolationMode: 'shared' | 'dedicated';
    status: 'active' | 'suspended' | 'soft_deleted';
    features: string[];                    // ['hr.employee', 'hr.leave']
    permissions: string[];                 // ['hr.employee.read', 'hr.leave.approve']
    scopes: Record<string, Scope>;         // permission → effective scope
    departmentId?: string;
    employeeId?: string;                   // resolves `self` scope inside HR
  };

  platform?: {
    roles: string[];                       // super-admin | product-admin | pricing-admin | support | support-write
    actingOnTenantId?: string;             // the ONLY way a platform user reaches tenant data
  };
}

type Scope = 'self' | 'department' | 'tenant';
```

### 3.3 Rules baked into the schema

- **`tenant` and `platform` are mutually exclusive.** A zod `refine` rejects an envelope
  carrying both or neither. This is the "never both" invariant from the design, made
  mechanical rather than remembered — checked at the gateway when minting *and* at every
  service when parsing.
- **`scopes` is keyed by permission, not by role.** A user holding the same permission
  through two roles gets the most permissive scope, resolved once at the gateway. The
  query layer reads one value and does not re-derive it.
- **`employeeId` is populated by the gateway**, not looked up in HR. Otherwise every
  self-scoped query in every module starts with a lookup.
- **`actingOnTenantId` is the admin data path** (trap 3.2 in the handoff). A platform user
  never implicitly gets tenant context. It is set only on routes under an explicit admin
  prefix, and every request carrying it is audit-logged with the platform user, the target
  tenant, the route and the timestamp.

### 3.4 Why not just forward the JWT

Because the token deliberately carries no entitlement or permission data. Forwarding it
would mean every service resolving its own entitlement — duplicated logic, N Redis reads
per request, and N places to get "fail closed" wrong.

---

## 4. Request pipeline, end to end

### 4.1 At the gateway

1. Extract bearer token. Missing → `401`.
2. Verify signature against **locally cached JWKS**. Unknown `kid` → refresh JWKS (rate
   limited, e.g. once per minute) and retry once, then `401`. No per-request call to Keycloak.
3. Validate `iss`, `aud`, `exp`, `nbf`.
4. Read `sub`, `tenant_id` (from the group-attribute mapper), realm roles.
5. **Invariant check**: `tenant_id` and a platform role both present → `401` and a
   security-level audit log. Neither present → `401`.
6. **Tenant path** — one Redis round-trip, two keys, pipelined:
   - `tenant:{tenantId}:entitlement` → `{ features[], status, isolationMode, packVersion }`
   - `tenant:{tenantId}:user:{userId}:perms` → `{ permissions[], scopes{}, departmentId, employeeId }`

   Miss on either → resolve from `erp-platform-core`, write back with TTL 30–60s, continue.

   > Keys are separate because their invalidation triggers differ — entitlement busts on
   > subscription change (tenant-wide), permissions bust on role change (one user or one
   > role's members). Pipelining keeps it **one network round-trip**, which is what the
   > "one Redis read per request" decision is actually protecting.

   - `status` is `suspended` or `soft_deleted` → `403`, except an allowlist (billing
     endpoints, export download, session logout).
7. **Platform path**: roles into the envelope. `actingOnTenantId` only on admin-prefixed
   routes, and audit-logged.
8. Mint envelope, sign, forward.

### 4.2 At the service

1. **`ErpContextMiddleware`** — header present? signature valid? version known? not expired?
   schema valid? Any "no" → `403`, fail closed. Bind to `AsyncLocalStorage`.
2. **`@RequireFeature('hr.employee')`** → is the feature in `ctx.tenant.features`?
   No → `403` with code **`FEATURE_NOT_ENTITLED`**.
3. **`@RequirePermission('hr.employee.read')`** → is it in `ctx.tenant.permissions`?
   No → `403` with code **`PERMISSION_DENIED`**. Audit-log the denial.

   > These two codes must never be collapsed (trap 3.6). `FEATURE_NOT_ENTITLED` is what the
   > portal turns into a greyed item with an upgrade prompt. `PERMISSION_DENIED` is what it
   > turns into nothing at all. Same HTTP status, different meaning, different UI.

4. **Connection acquisition** — `TenantConnectionProvider` branches on
   `ctx.tenant.isolationMode`; only the `shared` branch is implemented, `dedicated` is a
   stub that throws. All data access goes through it.
5. **Session variable**, inside a transaction:

   ```sql
   SET LOCAL app.tenant_id = $1;
   ```

   > **`SET LOCAL`, never plain `SET`.** With PgBouncer in transaction pooling mode a plain
   > `SET` persists on the physical connection after your transaction ends and is inherited
   > by the next borrower — which may be a different tenant. This is the single most
   > dangerous line in the stack. `SET LOCAL` is scoped to the transaction and released on
   > commit or rollback.

6. **RLS** does the tenant filter:

   ```sql
   USING (tenant_id = current_setting('app.tenant_id', true)::uuid)
   ```

   `current_setting(..., true)` returns NULL when unset, so an unset variable denies rather
   than errors — platform users with no tenant context are denied by default.

7. **Scope filter**, applied in the query layer *in addition to* RLS:
   - `self` → `employee_id = ctx.tenant.employeeId`
   - `department` → `department_id IN (subtree of ctx.tenant.departmentId)`
   - `tenant` → no additional predicate

   RLS answers *which tenant*. Scope answers *which records within it*. Neither replaces
   the other.

8. Response, in the shared error/success envelope from `@erp/contracts`.

### 4.3 Background jobs

Scheduled work never passes the gateway, so none of the above applies (trap 3.1). The
scheduler must, before dispatching any job:

1. Load the tenant's entitlement from the same Redis keys (or from
   `erp-platform-core` on miss).
2. Check the feature the job belongs to. Not entitled → skip, log, do not retry.
3. Mint a **system context envelope** with the same shape — `tenant` populated, `subject`
   set to a system principal, permissions set to the job's declared needs — so the job goes
   through the identical guard and RLS path as an HTTP request.

There is no second code path for jobs. A job that soft-locks must stop emailing reports on
the next tick, and the only reliable way to guarantee that is to make jobs use the same
enforcement code.

---

## 5. Fail-closed rules

Every one of these denies. None of them assume.

| Condition | Result |
|---|---|
| No context header | `403` |
| Bad or missing signature | `403` + security log |
| Unknown envelope version | `403` |
| Expired envelope (`expiresAt` passed) | `403` |
| Both `tenant` and `platform` present | `403` + security log |
| Neither present | `403` |
| `app.tenant_id` unset | RLS returns no rows |
| Feature not in `features[]` | `403 FEATURE_NOT_ENTITLED` |
| Permission not in `permissions[]` | `403 PERMISSION_DENIED` + audit |
| Redis unavailable at the gateway | Resolve from `erp-platform-core`; if that is also down → `503`, **never** a permissive default |
| Scheduler cannot resolve entitlement | Skip the job |

---

## 6. Database ownership

### 6.1 Schema per service

One Postgres database. One **schema** per service:

| Schema | Owner repo |
|---|---|
| `platform` | `erp-platform-core` (tenant, catalog, pack, subscription, RBAC) |
| `hr` | `erp-hr-service` |
| `billing` | `erp-billing-service` |

Rules:

- A service's migrations touch **only** the schema it owns. This is what stops two repos
  racing on one database.
- No cross-schema table joins across an ownership boundary. Read another service's data
  through its API, or through a view that service explicitly publishes and owns.
- `tenant_id` sits **directly** on every tenant-scoped table — never derived through a join.
- Surrogate primary key, with `tenant_id` separately indexed. **Not** a composite PK.
- Every tenant-scoped table has RLS enabled *and* forced.

### 6.2 Database roles

This is the part that silently fails if you get it wrong:

| Role | Rights |
|---|---|
| `erp_migrator` | Owns the tables. Runs migrations. Not used by any application. |
| `erp_app` | `SELECT/INSERT/UPDATE/DELETE` only. **No `BYPASSRLS`.** Not a table owner. |

```sql
ALTER TABLE hr.employee ENABLE ROW LEVEL SECURITY;
ALTER TABLE hr.employee FORCE ROW LEVEL SECURITY;
```

> **Why `FORCE`.** A table's owner bypasses its own RLS policies by default. If the
> application connects as the migration user — the default in most quick-start setups —
> RLS is enabled, looks correctly configured, and enforces nothing. `FORCE` closes this.
>
> The cross-tenant CI test must connect as **`erp_app`**, explicitly. A test running as the
> owner passes against a misconfigured database, which is worse than having no test.

### 6.3 Migration tooling

Deferred. Whatever is chosen must: run plain SQL (RLS policies, grants and `FORCE` are not
expressible in any ORM's generator), keep a **separate history table per schema** so each
repo migrates independently, and run as `erp_migrator` from a container in CI/CD rather
than from application startup.

---

## 7. Local development

`erp-dev-environment` provides:

- `docker-compose.yml`: Postgres, Redis, Keycloak + its own Postgres.
- A Keycloak realm export with the clients, mappers, platform roles and group structure
  already configured — so nobody configures a realm by hand twice.
- A seed script creating **two tenants with users in each**, so the cross-tenant test has
  something real to fail against from day one.
- Documented `yalc`/link workflow for iterating on `@erp/*` without publishing.

---

## 8. Build order

The vertical slice, in dependency order. Nothing here needs Kubernetes.

1. `@erp/contracts` — envelope schema first. Everything else references it.
2. `erp-dev-environment` — compose file + realm export + seed.
3. Database roles, one tenant-scoped table, RLS + `FORCE`, and **the failing cross-tenant
   test** in `@erp/testing`. Watch it fail correctly before anything else works.
4. `@erp/nest-platform` — context middleware, tenant connection provider, session interceptor.
5. `erp-gateway` — JWKS validation, the invariant check, envelope minting. Entitlement
   hardcoded at first.
6. A throwaway `GET /hello-tenant` in `erp-platform-core` that returns the row RLS lets it see.
7. Replace hardcoded entitlement with the real Redis lookup, and the guards.

Step 3 before step 5 is deliberate. If isolation does not hold, everything above it is
built on sand, and the test is the only way to know rather than assume.
