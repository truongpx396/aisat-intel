# Contract: Notification & Multi-Channel Delivery — **binding to `intel-notification`**

**Plan**: [../plan.md](../plan.md) | **Status**: Pointer + binding. The engine now lives upstream.

> ### The design moved
> The notification engine designed here — `Notifier`/`Channel`/`ChannelRegistry`/`Store`/
> `PreferenceStore`/`TemplateRenderer`/`AddressBook`/`TopicRegistry`/`Dispatcher` over an opaque
> `Recipient`/`Tenant`/`Topic`, the twelve invariants, the delivery-durability knob, the hexagonal
> layout, the machine-enforced boundary, the conformance suites — is now an independent, reusable
> project:
>
> ### 📦 **[truongpx396/intel-notification](https://github.com/truongpx396/intel-notification)**
> **Canonical contract**: [`specs/001-notification-core/contracts/notification-ports.md`](https://github.com/truongpx396/intel-notification/blob/main/specs/001-notification-core/contracts/notification-ports.md)
>
> Its git history came across intact, so this contract's evolution is traceable there. That
> repository is **authoritative** for the engine; this file records only how ContextEngine *binds*
> to it. Do not re-specify engine behaviour here — change it upstream.

This was always the plan. The contract's own litmus test was *"could I move this into its own repo
and have it compile with zero edits?"*, and the boundary was lint-enforced so the answer stayed yes.
It did, so it moved — the same path metering took to
[intel-payment](https://github.com/truongpx396/intel-payment).

---

## What ContextEngine supplies

The engine is generic; a host provides a `Realm`, an identity binding, its channels, its topics and
its templates.

| Binding | ContextEngine's value |
|---|---|
| **`Realm`** | `aisat-intel` |
| **`Tenant`** | `{Kind: "workspace", ID: workspace_id}` — Phase 2 re-anchors to `{Kind: "organization", …}`. A binding change here, not a migration ([draft-plan.md — Tenancy](../../draft-plan.md#phase-2--tenancy--delegated-administration)) |
| **`Recipient`** | `{Kind: "user", ID: user_id}` — the RLS predicate is `app.user_id` within `app.workspace_id` (FR-036, SC-012) |
| **`Channel`** | two registered: `InAppChannel` (Redis pub/sub `notify:user:<id>` → `cmd/relay` SSE) and `EmailChannel` (`kernel/mailer.go` → Resend, env-swappable). SMS/push/Slack/webhook are a `Register` call, not a fan-out edit |
| **`TemplateRenderer`** | per-topic Go/HTML templates for email, inbox item copy for in-app. i18n and per-tenant branding seam unused in Phase 1 |
| **`AddressBook`** | `in_app` → the recipient's `user_id`; `email` → the member's verified address, minus suppressions |
| **`AudienceResolver`** | `workspace_members` and `admins`, resolved from `workspace_members` — paged (upstream requires it; see change 4 below) |

## Topics (data upstream, values ours)

The 13 registered topics replace what was a Postgres `category` enum. A new one is a registration,
never an `ALTER TYPE`.

| Upstream concept | ContextEngine's configuration |
|---|---|
| `TopicRegistry` entries | `ingestion_complete` · `ingestion_failed` · `invite_received` · `invite_accepted` · `invite_revoked` · `credit_warning` · `credit_exhausted` · `task_halted` · `approval_requested` · `doc_shared` · `clearance_changed` · `member_joined` · `admin_broadcast` |
| `TopicDef.DefaultChannels` | in-app on for all; **email also on** for `credit_warning`, `credit_exhausted`, `invite_received`, `task_halted`, `approval_requested` — `approval_requested` because a paused agent action is actionable and time-sensitive |
| `TopicDef.DefaultPriority` | `critical` for `credit_exhausted` and `task_halted`; `warning` for `credit_warning` and `ingestion_failed`; `info` otherwise |
| `TopicDef.Essential` | `credit_warning`, `credit_exhausted`, `task_halted`, `approval_requested` — no unsubscribe footer, never digested |
| `Delivery` durability | `outbox` — multi-channel with an email side-effect is exactly the shape that loses sends without one |
| `Config.Shards` | 16 |
| Deployment shape | **embedded library** in `backend-go` (Go host, one product). The `Dispatcher` runs in `cmd/worker` as a queue-group consumer |
| `Bus` adapter | **`nats_jetstream`** — not the upstream default. Upstream defaults to Redis Streams to keep required infrastructure to Redis + Postgres, but this product already runs JetStream for ingestion, query, billing and the `*.tick` schedule, so the notify subjects stay on the same cluster ([nats-subjects.md](./nats-subjects.md)) |

## Where the seam touches this spec

| Concern | This repo |
|---|---|
| Producers | ingestion · billing · invite · agent-run · approval · admin BFF publish `notify.<ws>` ([nats-subjects.md](./nats-subjects.md)); thin by design |
| Recipient surface | `/notifications*` ([bff-rest.md](./bff-rest.md)), streamed per [sse-events.md](./contracts/sse-events.md), rendered per [notifications.md](../../../design-system/aisat-intel/pages/notifications.md) |
| Delivery workers | `notify.<ws>` fan-out + `notify.email.<ws>` email worker, N idempotent replicas in `cmd/worker` |
| Tasks | T011 defines `kernel/notify.go` against the upstream port set; Stage 10 (T129–T132e) tests this binding |

## Four upstream changes that affect this binding

All four were found or resolved during the extraction; the full list is upstream in
[design-decisions.md](https://github.com/truongpx396/intel-notification/blob/main/specs/001-notification-core/design-decisions.md).
The first two change **this repo's migrations**, so they are not optional reading.

1. **The idempotency guard must be a separate table.** `notifications` cannot be both
   `PARTITION BY RANGE (created_at)` *and* carry a global `UNIQUE (user_id, idem_key)` — PostgreSQL
   rejects the combination, and that index is the backstop for SC-013. Upstream uses a
   non-partitioned `notify_idem (realm, recipient_kind, recipient_id, idem_key)` guard written in the
   same transaction. **T019 currently specifies the unconstructible pair** and
   [data-model.md](../data-model.md) reflects the fix. This is the same defect
   [intel-payment found in `credit_ledger`](https://github.com/truongpx396/intel-payment/blob/main/PROVENANCE.md);
   one pattern was copied between two specs without either being applied.

2. **Preferences are rows, not columns.** Upstream keys
   `notification_preferences` on `(realm, tenant, recipient, topic, channel)` with one `enabled`
   flag, replacing `in_app BOOL, email BOOL`. The column pair made every new channel a migration,
   which contradicts the `Channel` registry this contract introduced to make a channel one
   `Register` call. T019 and [data-model.md](../data-model.md) follow the row shape.

3. **Storm coalescing needs a table this repo never had.** FR-038 requires a digest and
   `DeliverySchedule.Digest` names the window, but nothing held a deferred notification — the outbox
   drains an entry as soon as it is due, so there was nothing to collapse into. Upstream adds
   `digest_buffer` with one open window per `(recipient, topic, channel)`. **FR-038 was
   unimplementable as specified here**; T132b tests behaviour that needed this state to exist.

4. **`Broadcast` gained an `AudienceResolver` port, and it is paged.** FR-037 requires audience
   expansion off the request path, but no port existed to expand *through*, so a host could only
   implement it by calling `Notify` per recipient itself — moving the deterministic per-recipient
   `IdemKey` derivation into product code, where a retried broadcast double-notifies. Paging is part
   of the port: a non-paged resolver materializes a whole workspace's membership in memory.

Two further upstream refinements do not change this binding but do change operational expectations:
retry backoff is now **exponential with full jitter** (`MAX_DLQ_ATTEMPTS` alone was never a retry
policy), and quiet hours explicitly **yield to `critical`** — so a `credit_exhausted` notice is never
deferred to 07:00.
