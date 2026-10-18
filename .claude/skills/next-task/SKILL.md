---
name: next-task
description: Work through Task_Plan.md one task at a time — pick the next unchecked task, do it, test it, tick it, report, continue. Questions that need the owner are collected in QUESTIONS.md and do not stop the run. Use for "next task", "continue the plan", "work the task plan", /next-task.
---

# Task runner for the ERP SaaS plan

Work `planning/Task_Plan.md` top to bottom. One task at a time. **Keep going.**

All paths below are relative to the repo root (the `saas` repo). Infrastructure is at the
root (`gitops/`, `terraform/`, `ansible/`); application code goes in `app/`; the planning
documents are in `planning/`.

## State

The checkboxes in `Task_Plan.md` are the queue. No other tracking file.

- `- [ ]` todo
- `- [x]` done — tick it yourself when the task is finished and verified
- `- [?]` parked, waiting on the owner — the answer is pending in `QUESTIONS.md`
- `- [x] ~~text~~ → decision` is how already-settled items are written; match that style

Pick only `- [ ]` tasks. Skip `- [?]` — it has already been asked. When the owner answers,
turn it back into `- [ ]` and do it.

Open questions go in `planning/QUESTIONS.md` (create it if missing). Append, never rewrite.

## The rule that matters most

**Do not stop to ask.** A question parks the task, it does not end the run.

When a task needs the owner's decision:

1. Append it to `QUESTIONS.md` with enough context to answer without re-reading the plan,
   and your own recommendation.
2. Mark the task `- [?]` so it is not picked again.
3. **Move to the next task that is not blocked by that answer.**

Stop the run only on a **big block**: nothing left that is unblocked, a destructive action
needing approval, or a failure you cannot diagnose. Then notify once.

## Each task

```
pick first [ ] task  →  classify  →  act  →  verify  →  tick  →  commit  →  next
```

### Classify

| The task | Do this |
|---|---|
| Line starts with `OWNER:` | **Never answer it.** → QUESTIONS.md, skip |
| A business or legal choice (pricing, granularity, retention, which module) | → QUESTIONS.md, skip |
| Writes to the cluster: `terraform apply`, `helm install/upgrade/rollback`, ssh to a node, deleting PVCs | Show the plan, **ask, wait** — this one does stop |
| Code, schema, tests, config, docs, scaffolding | **Do it** |
| Ambiguous | Pick the reading a senior engineer would, write the assumption in the report, continue |

Design decisions already locked are in the "Decisions locked in" table at the top of
`Task_Plan.md`. Do not re-open them, and do not ask about them.

### Act

- Application code → `app/` (NestJS + Angular). Infrastructure → the repo root.
- Reuse what exists. Read `CLAUDE.md` before touching infrastructure.
- Smallest change that fully does the task. No extra features, options or abstraction.

### Verify — a task is not done because the file was written

- Code → run it, or run its test. New non-trivial logic leaves one small test.
- Infra → `terraform validate`, `helm lint`, `ansible-playbook --syntax-check`.
- Docs → re-read and check it matches reality, not intent.

If verification fails, fix it. If you cannot, leave the box unticked, write why in
`QUESTIONS.md`, and continue. Never tick a box you did not verify.

### Report

After each task, one short block: what you did, what you verified, what you assumed.
Plain words. No status dump.

## The VPN

The VMs are reachable only through FortiClient. Before any cluster task:

```powershell
Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*Fortinet*" }
```

`Ethernet 3` must be `Up`. **`Up` is not proof** — also test a real connection:

```powershell
Test-NetConnection 192.168.152.230 -Port 6443
```

When it is down:

1. Launch `"C:\Program Files\Fortinet\FortiClient\FortiClient.exe"`. If saved credentials
   and auto-connect are set, it reconnects on its own.
2. Re-probe every 30s, up to ~5 minutes.
3. Still down → **notify the owner once**, then switch to tasks that need no cluster.
   There are always some: code, schema, docs, tests.

**Never ask for, type, or store the VPN password.** FortiClient 7 has no connect CLI;
logging in is the owner's action. Do not try to automate around that.

Cluster failures that are the VPN look like `dial tcp … i/o timeout`, everything failing
at once. A failure that repeats at the **same step after the same elapsed time** is
deterministic — diagnose it, do not blame the VPN.

## Notify

Use `PushNotification` sparingly — it interrupts whatever the owner is doing.

Notify for: the question batch is worth answering (roughly 5+ open questions, or one that
blocks everything), a big block, VPN down after retries, or a destructive action awaiting
approval.

Do not notify for: a finished task, routine progress, or anything while the owner is
clearly at the keyboard.

## Hard rules

- Never answer an `OWNER:` question.
- Never run `terraform apply`, `helm upgrade`/`rollback`, or anything destructive without
  showing the plan and getting a yes.
- Never commit secrets: no passwords, kubeconfig, node token, `.tfvars`, sealing key.
- Never handle the owner's VPN or GitHub passwords.
- Push from WSL, not Windows git — the GitHub SSH key lives in WSL.
- One agent touches the cluster at a time.
- Report what actually happened, including what you skipped and could not verify.

## Phase 0 first

Most of Phase 0 is `OWNER:` decisions, and Phases 3 and 4 depend on them. Sweep it first
so the whole batch of questions reaches the owner in one go, then continue into Phase 1.
