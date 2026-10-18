# ERP SaaS — Handoff Document

**Purpose:** captures reasoning, rejected alternatives and cautions discussed during design
that are *not* fully recorded in the other project files. Read alongside:

- `ERP_SaaS_Documentation.md` — the architecture and every decision
- `Task_Plan.md` — phases, locked decisions, tasks
- `architecture.mermaid` — system diagram
- `ERP_SaaS_Phase_Plan.pptx` — owner/business presentation
- `ERP_SaaS_Technical_Design.pptx` — engineer presentation (**note: not yet updated with
  RBAC, feature-level entitlement, or platform access control — see "Known gaps" below**)

---

## 1. Project shape

Multi-tenant ERP delivered as SaaS. Client companies (tenants) subscribe to **packs** that
bundle **features**; each client's users hold **roles** granting **permissions** within
their tenant.

Target market at launch: **small enterprises**. This single fact drove most of the
architectural decisions below — several would have gone the other way for an
enterprise-first product.

**Stack:** Angular · NestJS · PostgreSQL · Keycloak · Redis · Kubernetes

---

## 2. Decisions, and what was rejected

Each of these was argued through. The rejected option is recorded because "why not X?"
will come up again.

### 2.1 Multi-tenancy: shared DB, not DB-per-tenant

**Chosen:** one PostgreSQL database, `tenant_id` column, Row-Level Security. Hybrid-ready —
`isolation_mode` field and a tenant resolution layer exist from day one so dedicated
databases can be added later as an enterprise tier.

**Rejected (for now):** database-per-tenant.

The owner initially favoured DB-per-tenant for three reasons. Assessment of each:

| Argument | Verdict |
|---|---|
| Easier backup/restore | **Strongest argument.** Per-client PITR with a shared schema is genuinely painful — restore to staging, extract one tenant's rows across every table in dependency order, merge back live. `pg_restore` is one line. For an ERP holding accounting data, "restore this client to last Tuesday" is a request you *will* get. |
| Paid dump/export feature | **Good instinct, but achievable either way.** Much less work and less risk when the boundary is physical, and selling data portability as a tier feature is a legitimate pattern. |
| Better security | **Weaker than it looks.** Dedicated DBs eliminate the "forgot the `WHERE tenant_id`" bug class, but *not* tenant confusion — if the resolution layer returns the wrong connection, data leaks just as badly, and that bug is **harder** to catch because it lives in infrastructure code rather than a query. RLS closes most of the gap. |

**Why shared won for this product:** per-database baseline cost (connections, memory, backup
slots, monitoring) is roughly fixed regardless of tenant size, so a 5-person client with 200
invoices costs nearly as much to host as a 200-person one. Onboarding stays an `INSERT`
rather than a provision-plus-migrate cycle. One migration to run instead of N, which matters
most while the schema is still volatile. And small enterprises do not ask for what dedicated
DBs buy — data residency clauses, contractual isolation, per-client PITR are enterprise
procurement requirements.

**What DB-per-tenant would have cost:** migration orchestration across N databases with
per-DB status tracking and partial-failure handling; connection explosion requiring PgBouncer
from day one; onboarding latency needing an async "provisioning" state; a cost floor that
hurts cheap self-serve tiers; and cross-tenant platform analytics needing a warehouse.

> **If the product had targeted tens of large enterprise clients instead, DB-per-tenant would
> have been the right call.** The decision is a function of client profile and volume, not a
> universal truth. Revisit if the target market changes.

### 2.2 Entitlements: resolved at gateway, not synced into Keycloak

**Chosen:** the API gateway reads the tenant's active feature set from Redis, once per
request, and forwards it downstream as trusted context.

**Rejected:** syncing entitlements into Keycloak (via Admin API on subscription change, with
a protocol mapper injecting an `active_modules` claim into the token).

| | Sync into Keycloak (rejected) | Gateway + Redis (chosen) |
|---|---|---|
| Propagation delay | Until the user's token refreshes | Seconds, via event-driven invalidation |
| Coupling | Identity layer coupled to the billing domain | Clean separation |
| Failure mode | A stale token grants access to a dropped module | Fails closed |

The deciding principle: **Keycloak answers "who is this user and which tenant."** Packs and
subscriptions are business data that change on a completely different cadence.

**Also rejected:** an in-process cache layer on top of Redis at the gateway. One Redis read
per request is cheap; premature cache layering makes invalidation bugs much harder to reason
about. Add only if profiling justifies it. *(The owner explicitly chose "no risk for the
moment, read from Redis" — this was a deliberate simplicity call, not an oversight.)*

### 2.3 Keycloak tenancy: groups, not realm-per-tenant

**Chosen:** single shared realm, tenant = Keycloak group, `tenant_id` as a **group
attribute** (not per-user — per-user attributes drift, and a user created without one
produces a token with no tenant).

**What realms would have bought, fairly stated:** hard isolation (separate user stores and
signing keys), per-tenant identity federation (enterprise clients wanting their own Azure
AD/LDAP), per-tenant login branding and password policy, and immunity to username
collisions across tenants.

**Why groups won:** no "apply to all realms" primitive exists, so every config change,
new backend client, or version upgrade must be applied N times through automation that
becomes critical infrastructure. Keycloak carries per-realm caches and config, with strain
reported in the hundreds of realms. Realm-per-tenant would reintroduce exactly the
per-tenant provisioning overhead the shared-database decision was made to avoid. And
cross-tenant support roles get harder — staff would need accounts in every realm, or an
admin realm with token exchange.

> **Caveat on the realm-count figures:** these come from community operational experience,
> not a formal Keycloak benchmark. The real ceiling depends on hardware and configuration.
> Load-test before ever committing to the realm path at scale.

**The position mirrors the database decision exactly: shared by default, isolated as a
premium tier on a real trigger.** The same enterprise client demanding a dedicated database
is usually the one wanting their own identity federation — so `isolation_mode` should cover
identity as well as data.

### 2.4 Authorization: RBAC with scope, not ABAC

**Rejected:** full attribute-based access control (evaluating arbitrary conditions per
request). Flexible, but slow to reason about and hard to debug.

**Chosen:** three layers — permissions (`module.resource.action`), roles as named bundles,
and **scope** (`self` / `department` / `tenant`) determining *which records*.

The scope layer is the part people skip. Without it, roles duplicate combinatorially
(`hr-viewer-own`, `hr-viewer-dept`) and become unmanageable. A manager and an employee may
both hold `hr.leave.read`; the difference is whose leave they see.

**Hard rule:** users get roles, **code checks permissions**. The moment anyone writes
`if (user.role === 'hr-manager')`, a policy decision that must stay configurable has been
hardcoded.

### 2.5 Tenant custom roles: application DB, not Keycloak

Tenants create and manage their own roles. These live in your database with
`UNIQUE (tenant_id, name)`.

**Why not Keycloak:** volume (hundreds of tenants × several roles = thousands of realm roles
in a flat namespace); wrong ownership (a tenant admin editing a role would trigger a Keycloak
Admin API write, granting the app config-write access to the IdP for routine operations);
staleness (changes would need to propagate into tokens — the same problem rejected for
entitlements).

**On the name-collision question:** with roles in your own DB this is structurally
impossible. Two tenants can both have a "Manager" role; they're unrelated rows with
different permission sets. Had roles lived in Keycloak's flat realm namespace, this would
have forced prefixing (`t_a1b2_manager`) — ugly, leaks tenant IDs into role names, and
breaks on tenant rename. **This is itself confirmation the DB approach is right.**

### 2.6 Platform staff and tenant users: one realm, separated by roles

**Rejected:** separate realms for the admin/subscription application and the ERP.

Two realms is trivially manageable (unlike hundreds). The problem is different: **platform
staff need to act on tenant data.** Support views a client's subscription; product-admin
changes a pack affecting live tenants. With separate realms every such operation crosses a
realm boundary, requiring token exchange or services accepting two issuers with two JWKS
sets and two claim shapes — a permanent complication in every service's auth layer.

**The invariant to enforce:** a token carries **either** a valid `tenant_id` **or** a
platform role, never both. Checked at provisioning *and* at the gateway. This is what
separate realms would have given structurally; here it must be actually checked, not assumed.

**Hardening obtained without a second realm:** separate Keycloak groups for staff with MFA
enforced at group level; separate OAuth clients for admin vs tenant portal with distinct
redirect URIs and a shorter admin session timeout.

### 2.7 Backend framework: NestJS, not Next.js

The owner's original stack proposal was Angular + **Next.js** + PostgreSQL.

**Next.js was rejected.** It is a React *frontend* framework; its backend capabilities (API
routes, server actions) exist to serve a React frontend. With an Angular frontend it would
run purely as an API server — losing everything that makes it valuable, while lacking what
an ERP backend needs: dependency injection and modular structure for a dozen services,
mature background job scheduling (required for recurring payroll and invoicing), guards and
interceptors (exactly where entitlement and permission checks belong), and strong ORM
integration with transaction and RLS session-variable support.

**NestJS** provides all of these natively and shares Angular's conventions (decorators, DI,
modules), so the team thinks in one paradigm across the stack.

*Alternatives that would also have been reasonable:* Spring Boot or .NET — both very common
in ERP and strong on transactional business logic. NestJS won because the team is in the
Node/TypeScript world.

### 2.8 Downgrade: soft-lock, never purge

Data is never touched. The gate lives entirely in the entitlement layer — no flags on
individual records. Re-upgrade is instant with everything intact.

**The commercial argument matters as much as the technical one:** a client who downgrades
seasonally and returns finds their data intact, making re-subscription frictionless. Purging
would make every downgrade a permanent loss and a support burden.

**Open option not yet decided:** a **read-only** middle tier (view historical data, cannot
create new records). Nicer experience, weaker upsell lever. **If wanted, it must be modelled
as a third entitlement state now** — bolting it on later is painful.

---

## 3. Traps and cautions raised during design

These are the things most likely to bite. Several are in the docs but are collected here
because they're easy to lose in a long document.

### 3.1 Background jobs bypass the gateway entirely

Scheduled work — recurring invoices, payroll runs, sync jobs, reports — does **not** traverse
the API gateway, so the entitlement check will not catch it. **The scheduler must check
feature entitlement before dispatching any job.** Otherwise a soft-locked Accounting module
will cheerfully keep emailing monthly reports to a client who no longer pays for it.

### 3.2 The admin data path is the most likely future cross-tenant leak

A platform user has no `tenant_id`, so `app.tenant_id` is unset and **RLS denies by default**.
The failure mode: someone builds an admin endpoint, RLS isn't satisfied, and the quick fix is
to bypass RLS entirely — at which point the safety net is gone for that code path forever.

**Design this path deliberately now.** Admin queries set tenant context explicitly and every
such access is logged. Do not let it grow ad hoc.

### 3.3 Hardcoded table lists go stale silently

Hard delete and per-tenant export both enumerate tenant-scoped tables. **Generate the list
from schema metadata, never hardcode it.** A static array goes stale the moment someone adds
a table, and the gap surfaces only at audit — or worse, at a GDPR deletion request that
didn't actually delete everything.

Run in a transaction and verify zero remaining rows for that `tenant_id` before committing.

**Note:** hard delete is the exact inverse of the future tenant-migration script (extract →
load → verify → delete). Same enumeration logic — **build it once**.

### 3.4 Permission naming convention must be locked before the first module ships

Once modules start registering permissions in inconsistent formats, it can never be fully
cleaned up. Fix `module.resource.action` before HR is written.

### 3.5 The menu is a UX affordance, not a security boundary

Hiding a menu item does not protect the endpoint. Every route still enforces entitlement and
permission server-side. Someone can always call the API directly.

### 3.6 "Not entitled" and "no permission" are different states — never collapse them

| State | Cause | UI |
|---|---|---|
| Locked | Tenant's pack lacks the feature | Greyed + upgrade prompt (visible upsell) |
| Hidden | User lacks the permission | Omitted entirely |

Telling a junior employee "upgrade to see salaries" is wrong on both counts: it isn't their
decision, and they shouldn't learn payroll exists.

### 3.7 Feature granularity is a one-way door in one direction

A feature can always be **split** later. **Merging** two that have already been sold
separately means migrating live subscriptions. Resist going finer than necessary until a
real pricing need appears.

### 3.8 Features within a module have prerequisites

`hr.payroll` is meaningless without `hr.employee` — you cannot run payroll for employees you
cannot see. A pack configured with Payroll but not Employee would produce a broken tenant.
Validate pack composition against declared prerequisites **at configuration time**, not when
a client subscribes.

### 3.9 Never hard-delete a feature

Removal from a manifest marks it **deprecated**. Active subscriptions may reference it and
historical invoices certainly do — deletion breaks billing history.

### 3.10 HR approval chains are relationships, not roles

An employee reads their own salary but not a colleague's. A manager approves their reports'
leave but not their own — someone else must approve the manager's. These derive from org
structure and are handled as an explicit relationship check inside the HR module.
**Attempting to encode "is this person's manager" as a Keycloak role will not work.**

### 3.11 Tenant-admin must not implicitly grant module permissions

`tenant-admin` manages users, roles and subscription. It must **not** implicitly grant
`hr.payroll.read`. Separating "administers the account" from "can see salaries" matters
generally, and in HR specifically it matters a lot.

### 3.12 Custom roles are left untouched on soft-lock

A tenant's custom role may grant `hr.payroll.approve` while HR is locked. **Leave the role
alone** — the entitlement check rejects the request regardless, and on re-upgrade everything
works with no repair step. Stripping now-invalid permissions would destroy tenant
configuration that cannot then be restored. Same principle as never touching data.

---

## 4. Open questions

### For the owner (blocking packaging, not the foundation)

1. **HR feature granularity.** Is `hr.employee` / `hr.leave` / `hr.attendance` / `hr.payroll`
   the right set of separately sellable units?
2. **Who assigns features to packs, and who sets prices?** Deliberately two separate
   permissions in the design; each needs a named owner. Recurring decisions, not one-offs.
   Without owners, features ship and sit unpriced and unsellable.
3. **Do pack changes reach existing subscriptions, or only new ones?** If Payroll is added to
   Growth, do current Growth tenants get it, or only tenants subscribing from now on?
   **If "only new", packs need versioning and subscriptions must pin to the version bought —
   a schema decision that must be made before billing is built.**

### Technical, still undecided

4. **Which module is second?** It determines what the plugin contract must generalise over —
   Accounting and Inventory stress it very differently. **Needed before the contract is
   written, which is before HR starts.**
5. **Read-only as a third entitlement state?** Model now or skip; retrofitting is painful.
6. **Payroll in or out of the HR MVP?** Currently deferred — most locale-specific part of HR
   and the largest scope risk.
7. **Message broker — Kafka or RabbitMQ?** Event volume is low at launch. RabbitMQ is simpler
   to operate; Kafka is the safer long bet.
8. **Sync vs async tenant provisioning?** Shared DB makes it fast enough to be synchronous
   today. Async costs little now and survives the dedicated-DB tier.
9. **API style for internal service-to-service calls** — REST or gRPC.
10. **Permissions fixed per module, or dynamically registerable?** Fixed is simpler and
    almost always sufficient, but means adding a permission requires a module release.
    Affects the plugin contract.

### Legal / compliance

11. **Statutory retention for financial records.** Accounting and invoicing data commonly
    carries 7–10 year retention requirements. The obligation may sit with the client while
    the data sits with the platform, and **GDPR erasure rights do not override statutory
    retention** — these can genuinely conflict. Common pattern: hard-delete operational data,
    retain minimum required financial records in a separate retention store, document in
    contract and privacy policy. **This is common practice, not legal advice** — confirm
    against Tunisian and EU rules with a qualified lawyer before building deletion.
12. **Payment provider regional availability and compliance** — must be verified before
    billing work starts. Stripe is the working assumption.

---

## 5. Recommended next steps

Agreed sequencing at the end of the design discussion:

1. **Write the module plugin contract spec.** Highest leverage remaining document. It turns
   the architecture into something a developer can build against, and HR is its first
   consumer. Needs: manifest file format, NestJS module registration, route entitlement
   declaration, migration plug-in points, export hooks, scheduled-job module ownership,
   naming conventions **with code examples, not just rules**. Every module after HR inherits
   whatever is set here — including the mistakes.
   *Blocked on: which module is second (question 4 above).*

2. **Write a one-page conventions doc.** API response and error shapes, how tenant context
   flows through a NestJS request, where scope filtering goes in the query layer, folder
   structure, testing expectations. Short and opinionated beats long and thorough.

3. **Build the vertical slice.** This is the real goal:

   > Tenant signs up → provisioned (Tenant record + Keycloak group + admin user) → admin logs
   > in via Keycloak → calls one trivial "hello tenant" endpoint → gateway verifies token
   > against cached JWKS, resolves entitlement from Redis, forwards context → tenant
   > resolution layer sets `app.tenant_id` → RLS scopes the query → correct data returns.

   Use a throwaway endpoint. No real HR module, no billing, no portal — just the plumbing.
   It touches every load-bearing piece of the architecture. **If something in the design is
   wrong, this surfaces it in week three rather than week fifteen.**

   **Write the cross-tenant access test first**, before the endpoint works. Watching it fail
   correctly once RLS is on is the only way to know isolation actually holds rather than
   assuming it does.

> **Caution raised at the end of the design discussion:** there is a failure mode where
> planning becomes the work. The architecture is in good shape — more documentation now has
> diminishing returns compared to proving it runs. The owner questions block *packaging*, not
> the foundation. **You can build the slice without knowing what Payroll costs.**

---

## 6. Known gaps in the project files

- **`ERP_SaaS_Technical_Design.pptx` is out of date.** It predates the RBAC model,
  feature-level entitlement, feature registration, platform-side access control, and the
  platform/tenant realm decision. Those are the topics an engineer is most likely to
  interrogate. **Update before presenting it.**
- The module plugin contract spec does not exist yet (step 1 above).
- No coding conventions document exists yet (step 2 above).
- HR feature set in the docs is a *proposal* pending owner confirmation.

---

## 7. Framing notes for presentations

**For the owner (non-technical):** the decision most likely to draw pushback is shared
database — "all clients share one database" sounds worse than it is. The answer: isolation is
enforced at the database level and tested automatically on every code change, and dedicated
databases remain available as a paid upgrade whenever a client's contract requires it.

Also: the 5–6 month figure is **engineering effort, not a calendar guarantee**. It's stated
on the slide, but people anchor on it anyway — say it out loud.

**For the engineer:** the sequencing point most likely to be argued with is **data
foundations before core services**. The defence: RLS, the tenant resolution layer, and the
schema rules are far harder to retrofit onto live data than to establish first.
