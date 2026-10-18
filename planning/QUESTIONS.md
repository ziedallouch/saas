# Open questions for the owner

Raised by the task runner. Each one parks a task in `Task_Plan.md`, marked `- [?]`.
Answer here or in chat; the runner turns them back into `- [ ]` and does them.

Ordered by what blocks the most work.

---

## Q1 — Do pack changes reach existing subscriptions, or only new ones?

**Phase 0 · blocks the Phase 3/4 schema. Answer this one first.**

If a pack change reaches existing subscribers, a pack is a living object and a
subscription just points at it. If it reaches only new ones, **packs need versioning** and
each subscription pins the version it bought.

This cannot be retrofitted cheaply: it changes `PackFeature`, `Subscription` and every
entitlement lookup. It also decides whether "we added a feature to Growth" is a silent
upgrade for 200 existing clients or a migration you run deliberately.

**My recommendation: version the packs, subscriptions pin a version.** Slightly more
schema now, and it is the only option that lets you change pricing and composition without
silently altering what people already pay for. It also gives you the impact preview
(`"this affects 47 tenants"`) the plan already asks for in Phase 4.

---

## Q2 — Is read-only a third entitlement state?

**Phase 0 · decide now or never (`ERP_SaaS_Documentation.md` §9).**

Today a module is entitled or soft-locked. A third state would let a downgraded client
read historical data but create nothing.

Your own documentation calls it "nicer experience, weaker upsell lever", and warns that
bolting it on later is the expensive path.

**My recommendation: skip it. Two states.** Soft-lock already keeps the data intact and
makes re-upgrade instant, which is the commercial argument that matters. A third state
multiplies every entitlement check and every navigation rule by 1.5 for a benefit you have
not yet had a client ask for. If you disagree, model it now — not later.

---

## Q3 — Which module is second?

**Phase 0 · decides what the plugin contract must generalise over.**

HR is people-centric. If the second module is also people-centric, the contract will fit
both by accident and break on the third.

**My recommendation: something document-centric — Inventory/Stock, or CRM/Sales.** It
stresses different parts of the contract (documents, lines, stock movements, approval
chains) and proves the feature/permission/navigation model is not HR-shaped. You already
have deep domain knowledge of both from DUX.

---

## Q4 — Confirm HR feature granularity

**Phase 0 · `OWNER:` — not mine to answer.**

Is `employee` / `leave` / `attendance` / `payroll` the right set of separately sellable
units? The question is commercial, not technical: each one becomes a thing a client can
buy or not buy, and a `@RequireFeature` boundary in the code.

Worth knowing before you answer: splitting is cheap now and expensive later (a feature that
ships bundled cannot be unbundled without re-pricing existing subscriptions), but every
split adds a boundary to test.

---

## Q5 — Who assigns features to packs, and who sets prices?

**Phase 0 · `OWNER:` — not mine to answer.**

These are two separate recurring decisions, and the plan already requires them to be two
separate permissions (`product-admin` vs `pricing-admin`). The question is which human
holds each, because that decides whether one person can both invent a feature and price it.

---

## Q6 — MVP pack tiers and pricing

**Phase 0 · `OWNER:` — not mine to answer.**

Starter / Growth / Enterprise: which features in each, at what price. Blocked behind Q4
(you cannot compose packs from features that are not yet defined) and shaped by Q1.

---

## Q7 — Payment provider, and does it actually serve Tunisia?

**Phase 0 · blocks Phase 5.**

Your documentation recommends **Stripe** (§13), with "or a local/regional PSP if needed for
market compliance".

**Flag before you plan around Stripe: check whether Stripe can onboard a Tunisian
business.** Stripe's supported-countries list is narrow, and I believe Tunisia is not on
it — but I have not verified this, and it would be a serious thing to discover in Phase 5.
If it is not supported, the realistic options are a local PSP (Paymee, Flouci, Konnect,
ClicToPay) or billing through an EU entity.

**Please confirm the merchant country before anything else here.** The answer changes the
Billing Service design: local PSPs generally do not offer Stripe-style subscription
billing, so recurring billing, proration and dunning would become yours to build rather
than the provider's.

---

## Q8 — Statutory retention for financial records

**Phase 0 · needs a qualified lawyer, Tunisian + EU.**

How long must invoices and financial records be kept, and what may be deleted on a GDPR
erasure request? This shapes the hard-delete design: some rows must survive a tenant's
deletion.

I am not able to answer this and should not guess — a wrong retention period is a legal
exposure, not a bug. Your plan already says "with a qualified lawyer", which is right.

**One technical note for whoever asks:** the conflict is between GDPR erasure and statutory
retention of invoices. The usual resolution is that financial records are retained under a
legal obligation while personal data elsewhere is erased — which means your hard-delete
needs a per-table rule, not one switch. Worth designing for even before the legal answer
arrives.
