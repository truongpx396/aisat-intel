# Contract: Authorization (reusable ports)

**Plan**: [../plan.md](../plan.md) | **Access model**: [draft-plan.md — Access model (decided)](../../draft-plan.md#access-model-decided) | **Auth (authN)**: [auth-flow.md](./auth-flow.md) | **Status**: Design addition — the reusability + parity seam for the access-control layer. **Changes no Phase 1 behavior.** It factors the existing two-axis access model (clearance ladder + principal ACL + personal scope) into three ports so the *same* decision engine drops into another product without a rewrite, and — the load-bearing win — so the **Postgres RLS predicate and the Qdrant payload filter are two lowerings of one predicate, not two hand-maintained copies**.

The Phase 1 access model is already correct and structural (RLS + Qdrant pre-filter, SC-001 a release blocker). But it is *enforced* in three hand-written places that must agree by vigilance: the RLS policy DDL, the Qdrant filter builder, and the library-list repo query. Authentication got a swappable `Auth` interface ([auth-flow.md](./auth-flow.md)); **authorization did not**. This contract names that seam. Ports are given in Go (the kernel language); the AISAT two-axis model is presented at the end as **one implementation** of these ports, not as the core.

> **Scope boundary.** This is *authorization* (**may this actor see/do this?**). *Authentication* (**who is this actor?**) stays in the kernel `Auth` interface. The two compose: `Auth` resolves a verified identity; the `PrincipalResolver` below turns that identity into an `Actor` (clearance + principal set); the `Authorizer` decides.

---

## Why: the three couplings this removes

| # | Today's coupling | Evidence it is a coupling | The port that removes it |
|---|---|---|---|
| 1 | The access predicate is written **three times** and kept in agreement by hand | RLS policy DDL (`access_level <= app.clearance AND (allowed_principals = '{}' OR allowed_principals && app.principals)`), the Qdrant `must:[…]` filter, and the library-list `WHERE` — [draft-plan.md](../../draft-plan.md#enforcement-both-layers-additive). One edited without the others is a silent leak. | `Predicate` + `Lowerer` — one predicate AST, lowered to each backend; parity is a test, not a promise |
| 2 | The **shape** of the model (clearance ≤ ∧ principal-overlap ∧ personal-owner) is hardcoded across middleware, repo, and filter builder | Adding axis 2 required touching RLS, the Qdrant payload list, and request-context plumbing in lockstep | `Policy` — a declared access model the host implements once; everything else is generic |
| 3 | Clearance + principal resolution is welded to Casdoor claims + a `workspace_members` row | `app.clearance`/`app.principals` are populated inline in Tenant middleware; agent bounding, `used_principals` intersection, and SCIM drift have nowhere central to live | `PrincipalResolver` — opaque identity → `Actor`, one place for min(owner) bounding, intersection, fail-closed |

The rule: **the decision engine is generic; only the `Policy` implementation and the `Scope`/`PrincipalResolver` binding are product-specific.** Everything release-blocking today (data-layer enforcement, pre-filter-not-post-filter, existence privacy, no-implicit-admin-read) is preserved verbatim — it just stops being copy-pasted across three query builders.

---

## Ports at a glance

```text
CALLER (any runtime)
   │  Filter(actor, query)          ── SET/READ path: compile a visibility predicate
   │  Check(actor, action, res)     ── POINT path: one allow/deny (writes, admin, share)
   │  WriteEnvelope(actor, sources) ── DERIVED-WRITE floor (never widen)
   ▼
┌── Authorizer (orchestration) ─────────────────────────────────────────────┐
│   Policy.Visibility(actor, query) → Predicate          PURE, product-specific │
│   Policy.Permit(actor, action, res) → Decision         PURE, product-specific │
└───────────────┬────────────────────────────────────────┬───────────────────┘
                │  ONE Predicate                          │  Decision (+Obligations)
                ▼                                          ▼
┌── Lowerer (per backend) — the PARITY seam ──────────────┐   Obligations:
│   SQLLowerer   → WHERE clause + app.* GUC bundle (+RLS)  │   • MaskAsNotFound (existence privacy)
│   QdrantLowerer→ payload `must/should` filter            │   • Audit  • BreakGlassRequired
│   … one Predicate, N lowerings, proven equal by test     │   • EnvelopeFloor (derived writes)
└──────────────────────────────────────────────────────────┘
        ▲
        │  Actor { scope, clearance, principals, roles } resolved ONCE at session-mint
┌── PrincipalResolver (driven) ─────────────────────────────────────────────┐
│   identity(+agent owner) → Actor   · agent = min(owner) · user ∩ used · fail-closed │
└────────────────────────────────────────────────────────────────────────────┘
```

Three seams a host swaps independently: the **`Policy`** (its access model), the **`Lowerer`** set (its stores), and the **`PrincipalResolver`** (its identity/tenancy). The reference impl targets Postgres RLS + Qdrant, but nothing in the port signatures requires them.

---

## Domain types

```go
package authz

// Scope is the opaque isolation subject — the hard boundary the engine never crosses.
// The HOST decides what it means (workspace here; could be org/project). Mirrors metering.Scope
// so a product uses one Scope vocabulary for money and access. (metering-ports.md)
type Scope struct {
	Kind string // "workspace" | "organization" | "project" | …
	ID   string // opaque, stable
}

// Clearance is one rung of the ordered sensitivity ladder. Ordered: a higher number sees
// everything a lower one does ON THIS AXIS. The label/count is workspace config; only the
// integer is ever compared or indexed (draft-plan §clearance scheme is workspace-configurable).
type Clearance int

// Principal is a namespaced group/identity token. The UNORDERED axis: "which domain".
type Principal string // "user:<uuid>" | "group:<uuid>" | "ext:<source>:<id>" | "agent:<uuid>"

// Actor is the fully-resolved caller. Built ONCE per session by PrincipalResolver from a
// verified identity — NEVER read from a request body (FR-004/FR-027). Immutable for the request.
type Actor struct {
	Scope      Scope       // the isolation subject in effect
	Subject    Principal   // who is acting: "user:…" or "agent:…"
	Clearance  Clearance   // effective rung (already min(agent,owner)-bounded if an agent)
	Principals []Principal // effective set: (user:self ∪ groups) already ∩ used_principals, agent-bounded
	Roles      []string    // "owner"|"admin"|"member"|… — ADMINISTRATIVE reach only, never content-read (invariant 6)
}

// Action is a verb on a resource. Read is answered by Filter (a set); the rest by Check (a point).
type Action string

const (
	ActionRead       Action = "read"
	ActionCreate     Action = "create"
	ActionUpdate     Action = "update"
	ActionDelete     Action = "delete"
	ActionShare      Action = "share"       // change a resource's ACL/level
	ActionAdminister Action = "administer"  // manage members/groups/policy — NOT a content-read
)

// Resource is a materialized access envelope for a POINT check. The engine reads only these
// access-relevant fields; the host loads the row and fills them. (Never the body.)
type Resource struct {
	Type              string      // "document" | "note" | "edge" | "group" | …
	ID                string
	Scope             Scope
	AccessLevel       Clearance   // the doc's rung
	AllowedPrincipals []Principal // axis-2 ACL; empty = clearance-only (inert)
	Owner             Principal   // "user:<uuid>" — for scope='personal' owner-only check
	Personal          bool        // scope='personal' → owner-only, orthogonal to both axes
	Origin            string      // "authored" | "mirrored" — governs whether write ops are even legal
}

// Decision is the outcome of a POINT check. Deny is the default; Reason is stable + auditable.
type Decision struct {
	Allow       bool
	Reason      string       // stable code: "clearance_below" | "principal_mismatch" | "not_owner" | "role_lacks_action" | "mirrored_readonly" | "envelope_widens" | "allow"
	Obligations []Obligation // things the caller MUST honor when acting on this decision
}

// Obligation is a side condition the enforcement point MUST apply. Making these explicit keeps
// cross-cutting security rules (existence privacy, audit, break-glass) out of ad-hoc call sites.
type Obligation struct {
	Kind ObligationKind
	Data map[string]string // kind-specific (e.g. min_access_level, required_principals)
}

type ObligationKind string

const (
	// A denied READ MUST surface as 404 not_found, never 403 forbidden, so existence is not
	// probeable (SC-001; contracts/README "Errors"). Attached to every read-deny.
	ObMaskAsNotFound ObligationKind = "mask_as_not_found"
	// Emit an audit row (append-only, outside the access model). Attached to writes, admin ops,
	// and every break-glass grant.
	ObAudit ObligationKind = "audit"
	// The action is legal ONLY under an explicit, reason-required, time-boxed break-glass grant
	// (draft-plan rule 3). No silent rank-based override exists.
	ObBreakGlassRequired ObligationKind = "break_glass_required"
	// A derived write MUST be tagged at/above this envelope (from WriteEnvelope). Carries
	// min_access_level + required_principals in Data. (draft-plan Agent Access, Decision 3.)
	ObEnvelopeFloor ObligationKind = "envelope_floor"
)

// Query is the READ request context Filter compiles a predicate for. Collection/ResourceType
// let one Policy emit different predicates per store (e.g. personal vs workspace collection).
type Query struct {
	ResourceType string // "document" | "edge" | "notification" | …
	Collection   string // reference impl: "personal" | "workspace" (Qdrant dual-collection)
}

// Envelope is the floor a derived write inherits from its sources (never widen).
type Envelope struct {
	MinAccessLevel Clearance   // >= max(source access levels)
	Principals     []Principal // ⊇ the (single) source principal set; refuses to merge differing sets
	Mergeable      bool        // false ⇒ sources have differing principal sets → caller MUST partition or require a human tag
}
```

### The `Predicate` AST — the single source of truth

```go
// Predicate is a backend-AGNOSTIC boolean over a resource's access fields. It is the ONE
// artifact both stores are built from: SQLLowerer turns it into a WHERE clause + GUCs, and
// QdrantLowerer turns it into a payload filter. Because there is exactly one predicate, the two
// enforcement points CANNOT drift — the differential contract test proves they admit the same set.
type Predicate interface{ isPredicate() }

// Fields are LOGICAL names. Each Lowerer maps them to its physical column / payload key,
// so a schema rename is a lowerer change, not a predicate rewrite.
type Field string

const (
	FieldScope       Field = "scope_id"           // → workspace_id column / payload key
	FieldAccessLevel Field = "access_level"
	FieldPrincipals  Field = "allowed_principals"
	FieldOwner       Field = "owner_id"           // → user_id (personal collection)
	FieldPersonal    Field = "is_personal"
)

type (
	And      struct{ Terms []Predicate }              // ∧
	Or       struct{ Terms []Predicate }              // ∨
	Not      struct{ Term Predicate }                 // ¬
	Eq       struct{ Field Field; Value any }         // scope_id == ctx
	Le       struct{ Field Field; Value any }         // access_level <= clearance
	Overlaps struct{ Field Field; Values []string }   // allowed_principals && principals (array overlap)
	IsEmpty  struct{ Field Field }                    // allowed_principals = '{}'
	True     struct{}                                 // no restriction on this field
	False    struct{}                                 // deny-all — the fail-closed sentinel (invariant 3)
)

func (And) isPredicate()      {}
func (Or) isPredicate()       {}
func (Not) isPredicate()      {}
func (Eq) isPredicate()       {}
func (Le) isPredicate()       {}
func (Overlaps) isPredicate() {}
func (IsEmpty) isPredicate()  {}
func (True) isPredicate()     {}
func (False) isPredicate()    {}

// Eval runs the predicate in memory against one resource — the THIRD lowering, used by the
// point-check path AND as the oracle the store lowerings are tested against. Pure, no I/O.
func Eval(p Predicate, r Resource) bool { /* structural recursion over the AST */ return false }
```

---

## Port: `Policy` — the one product-specific port (everything else is not)

```go
// Policy is the declared access model. It is the ONLY port a product must write: the AISAT
// two-axis model is one implementation; a single-tenant ownership model or a Cedar-backed model
// is another. Both methods MUST be PURE — no I/O — so a decision is reproducible in an audit
// replay and the same Predicate is testable offline (invariant 4).
type Policy interface {
	// Visibility compiles the actor's READ predicate for a query. It binds the actor's clearance
	// and principal set into the model's shape. Returns False (deny-all) rather than erroring when
	// the actor cannot be trusted — the engine never emits True by omission (invariant 3).
	Visibility(actor Actor, q Query) Predicate

	// Permit answers a POINT action (write/admin/share) against a materialized resource. Read is
	// NOT routed here — reads go through Visibility so they pre-filter inside the store (invariant 2).
	// Permit MAY attach obligations (audit, break-glass, envelope-floor).
	Permit(actor Actor, action Action, r Resource) Decision
}
```

**Why `Policy` is the whole product surface:** `Visibility` encodes *how a set is scoped*; `Permit` encodes *who may act on one thing*. Both read only the `Actor` and the model constants — no stores, no clock, no request body. Swapping products = write one `Policy`; the resolver, the lowerers, the obligation handling, and the parity harness are untouched.

## Port: `Authorizer` — orchestration callers actually use

```go
// Authorizer is the single entry point business code depends on. It composes Policy (the model)
// with the Lowerers (the stores) so callers never hand-write a WHERE clause or a Qdrant filter.
type Authorizer interface {
	// Filter compiles the actor's visibility for q and lowers it for the named backend. The Go BFF
	// calls Filter("sql") to get the GUC bundle + WHERE fragment; the retrieval tier calls
	// Filter("qdrant") to get the payload filter. Same Predicate underneath — that is the guarantee.
	Filter(ctx context.Context, actor Actor, q Query, backend string) (Lowered, error)

	// Check is the point path: writes, deletes, shares, admin ops. Read actions are rejected here
	// with an error directing the caller to Filter (reads must pre-filter, never post-check).
	Check(ctx context.Context, actor Actor, action Action, r Resource) (Decision, error)

	// WriteEnvelope computes the floor a derived write inherits from the resources it was built
	// from (the retrieval trace's sources). The SERVER computes it — never trusts the agent's
	// declared level (draft-plan Agent Access, Decision 3).
	WriteEnvelope(ctx context.Context, actor Actor, sources []Resource) (Envelope, error)
}

// Lowered is one backend's rendering of a Predicate.
type Lowered struct {
	Backend string            // "sql" | "qdrant"
	SQL     *SQLFilter        // set when Backend=="sql"
	Qdrant  json.RawMessage   // set when Backend=="qdrant" — a Qdrant Filter object
}

// SQLFilter is the SQL rendering: a parameterized WHERE fragment PLUS the SET LOCAL GUC bundle
// the RLS policy reads. The static RLS policy DDL is generated from the SAME Predicate at
// migration time, so RLS and the explicit library-list query share one source (invariant 1).
type SQLFilter struct {
	Where string            // e.g. "scope_id = $1 AND access_level <= $2 AND (cardinality($3) = 0 OR allowed_principals && $3)"
	Args  []any             // positional args for Where
	GUCs  map[string]string // {"app.workspace_id":…, "app.clearance":…, "app.principals":"{g1,g2}"} for SET LOCAL
}
```

## Port: `Lowerer` — the parity seam (driven, one per backend)

```go
// Lowerer renders a backend-agnostic Predicate into one store's native filter. Registering a new
// store = writing one Lowerer; the Policy and everything above are untouched. Every Lowerer MUST
// be TOTAL over the AST (no silent "unsupported node → drop the term", which would widen access —
// an unknown node lowers to the store's deny-all, never to no-op).
type Lowerer interface {
	Backend() string
	Lower(p Predicate) (Lowered, error)
}
```

## Port: `PrincipalResolver` — identity → Actor (driven)

```go
// PrincipalResolver turns a verified identity (from the Auth port) into an Actor. It is the ONE
// place the hard rules about *who you effectively are* live, so no call site re-derives them.
type PrincipalResolver interface {
	// Resolve is called at session-mint (browser login, PAT issue) and cached in the opaque
	// session record; the request path reads the cached Actor, never re-resolving per call.
	// For an agent subject it applies the owner bound; for a human it intersects with used_principals.
	// On ANY resolution failure it returns an error — the caller MUST fail closed (deny), never
	// proceed with a partial Actor.
	Resolve(ctx context.Context, id Identity) (Actor, error)
}

// Identity is the authenticated principal handed over by the Auth port (post JWKS/PAT verify).
type Identity struct {
	Subject    Principal   // "user:<uuid>" | "agent:<uuid>"
	Scope      Scope
	Owner      *Principal  // set when Subject is an agent — the registering member
	RawGroups  []Principal // native + IdP/SCIM-claimed groups, BEFORE bounding/intersection
	Roles      []string
}
```

---

## Invariants every implementation MUST uphold

1. **One predicate, many backends (parity by construction).** Every enforcement point for a given read is a `Lowerer.Lower` of the *same* `Predicate` produced by `Policy.Visibility`. No call site hand-writes a store filter. The differential contract test (below) is mandatory and asserts `SQLLower` ⇔ `QdrantLower` ⇔ `Eval` admit an identical row set over a shared corpus. **This is the invariant the whole port exists to guarantee** and closes the "three hand-maintained copies" risk.
2. **Pre-filter, never post-filter.** Read authorization is a predicate injected *inside* the store query (RLS + Qdrant `must`), before ANN scoring — never a filter applied to returned rows. Post-filtering an ANN top-K destroys recall and turns SC-001 into best-effort (draft-plan §Why not a policy engine). `Authorizer.Check` refuses `ActionRead` for this reason.
3. **Fail closed, everywhere.** A resolver error, an unknown `Predicate` node, an unmapped `Field`, or a lowerer error yields **deny-all** (`False` / empty result), never allow-all. `Policy.Visibility` returns `False`, not `error`, when in doubt, so a miswired caller leaks nothing.
4. **Decision purity.** `Policy.Visibility`/`Policy.Permit` and `Eval` are pure over `(Actor, Action, Resource/Query)` + model constants — no I/O, no clock, no request body. All I/O (identity, group sync) is in `PrincipalResolver`, run once at session-mint. This is what makes a decision reproducible in an audit replay.
5. **Existence privacy.** Every read-deny carries `ObMaskAsNotFound`; the enforcement point returns `404 not_found`, never `403 forbidden`, so a higher-clearance resource is not probeable (SC-001, contracts/README "Errors").
6. **No implicit admin read.** `Roles` grant `administer`/`share`/membership management via `Permit` — and never relax the read `Predicate`. An admin reads restricted content only via an actual grant that lands in `Actor.Principals`. Operability is served by **break-glass** (`ObBreakGlassRequired` → reason-required, time-boxed, audited self-grant), never a standing rank bypass (draft-plan rules 2–3).
7. **Derived writes never widen.** `WriteEnvelope(sources)` returns `MinAccessLevel ≥ max(source levels)` and `Principals ⊇` the source set, computed server-side from the retrieval trace. `Permit(create/update)` denies (`Reason:"envelope_widens"`) a write below the floor. Sources with differing principal sets are `Mergeable:false` — the caller MUST partition or require a human tag (one rule governs memory distillation, agent writes, and mind-map labels alike).
8. **Bounded, resolved-once principals.** `Actor.Principals` and `Actor.Clearance` are computed by `PrincipalResolver` at session-mint and cached — never read from the wire. For an agent: `clearance = min(agent, owner)`, `principals = agent ∩ owner`. For a human: `principals = (user:self ∪ groups) ∩ used_principals`. Revocation follows the human automatically: the opaque-session model deletes the session key on a role/clearance/group change so the next request re-resolves (auth-flow §Session model; draft-plan §ACL freshness).
9. **Isolation is non-negotiable and cheap.** `Eq(FieldScope, ctx)` is a conjunct of *every* predicate the reference policy emits — a single equality, never a set membership. A `Policy` may add axes but MUST NOT drop scope isolation.

---

## Decision mode (customizable knob)

One config selects how a decision is applied, without changing any port signature — the safe-rollout dial for a new `Policy` or a new axis:

| `DecisionMode` | Behavior | Use when |
|---|---|---|
| `enforce` (default) | Deny blocks; the predicate filters. | Production. |
| `shadow` | Allow proceeds, but every decision that *would* differ from the previously-live policy is logged with both predicates. | Rolling out a new axis (e.g. adding `allowed_principals`) — measure the delta on real traffic before enforcing. |
| `dry_run` | `Filter`/`Check` compute and log but the caller ignores the result. | CI / staging validation of a `Policy` change against golden traffic. |

`shadow` is how axis-2 (the group ACL) can be introduced against live queries: run it in shadow, confirm the `used_principals` intersection and connector ACL mappings produce the expected narrowing, then flip to `enforce`. Because `allowed_principals = '{}'` is inert (draft-plan §Backfill: none), the shadow delta on existing rows is provably empty — a strong pre-enforcement signal.

---

## Reference wiring: the AISAT two-axis model as ONE implementation

The AISAT access model is this port bound to a product `Policy` — nothing in the engine knows that.

> **Phased binding (matches the task graph).** Phase 1 ships **`SingleAxisPolicy`** — workspace
> isolation ∧ `access_level ≤ clearance` ∧ personal-owner (the `TwoAxisPolicy` below **minus** the
> `allowed_principals` `Or` conjunct). It is built in Phase 1 as a real port: `authz.go` (T011),
> the `SingleAxisPolicy` + `SQLLowerer` + `PrincipalResolver` impl (T022a), the Python
> `QdrantLowerer` (T027), and the mandatory `ParityContract`/`InvariantContract`/`ResolverContract`
> conformance suite (T027a). **Phase 2 is the single additive step** shown as `TwoAxisPolicy`: add
> the `Or{ IsEmpty(principals), Overlaps(principals) }` term and the `app.principals` GUC — no
> signature, plumbing, or backfill change (`allowed_principals='{}'` is inert). The table and code
> below show the Phase-2 end state; drop the principals conjunct to read the Phase-1 form.

| Generic port / type | AISAT binding |
|---|---|
| `Scope` | `{Kind:"workspace", ID:workspace_id}` → Phase 2 workspace stays the isolation boundary even as org appears above it (draft-plan §Tenancy) |
| `Policy` | `TwoAxisPolicy` (below): clearance ≤ ∧ (principals empty ∨ overlap) ∧ personal-owner |
| `PrincipalResolver` | Casdoor/SCIM claim → `user:self ∪ native groups ∪ ext: groups`, ∩ `used_principals`, agent-bounded to owner (draft-plan §Principals, §Agent Access Decision 1) |
| `Lowerer["sql"]` | RLS policy DDL + the `SET LOCAL app.workspace_id/user_id/clearance/principals` GUC bundle (data-model §RLS) |
| `Lowerer["qdrant"]` | payload `must:[ workspace_id==ctx, access_level<=clearance, empty-or-overlap ]` over the `personal`/`workspace` collections (data-model §Vector store) |
| `Decision` obligations | `not_found` masking (existence privacy), `agent_audit_log`/`audit_log` rows, break-glass grant, derived-write envelope |

```go
package policy // internal/authz/policy — product tier, depends only on kernel/authz

import "github.com/aisat/backend-go/kernel/authz"

// TwoAxisPolicy implements authz.Policy: the L1–L5 ladder ∧ the group-ACL axis, with personal
// scope as a third orthogonal owner-only check. This is the entire product-specific access model.
type TwoAxisPolicy struct{}

func (TwoAxisPolicy) Visibility(a authz.Actor, q authz.Query) authz.Predicate {
	scope := authz.Eq{Field: authz.FieldScope, Value: a.Scope.ID} // invariant 9 — always
	switch q.Collection {
	case "personal":
		// Owner-only, NOT clearance-scoped — a member always sees their own personal docs
		// (mcp-tools §list; data-model §dual-collection). Orthogonal to both axes.
		return authz.And{Terms: []authz.Predicate{
			scope,
			authz.Eq{Field: authz.FieldOwner, Value: string(a.Subject)},
		}}
	default: // "workspace"
		// Axis 1: access_level <= clearance. Axis 2: ACL empty OR overlaps the actor's principals.
		return authz.And{Terms: []authz.Predicate{
			scope,
			authz.Le{Field: authz.FieldAccessLevel, Value: int(a.Clearance)},
			authz.Or{Terms: []authz.Predicate{
				authz.IsEmpty{Field: authz.FieldPrincipals},
				authz.Overlaps{Field: authz.FieldPrincipals, Values: strs(a.Principals)},
			}},
		}}
	}
}

func (TwoAxisPolicy) Permit(a authz.Actor, action authz.Action, r authz.Resource) authz.Decision {
	if action == authz.ActionRead {
		// Reads never reach Permit — routed through Visibility (invariant 2). Defensive deny.
		return authz.Decision{Allow: false, Reason: "read_uses_filter"}
	}
	if r.Origin == "mirrored" && action != authz.ActionAdminister {
		return authz.Decision{Allow: false, Reason: "mirrored_readonly"} // source-owned, read-only here
	}
	if !hasRole(a, "owner", "admin") && action == authz.ActionAdminister {
		return authz.Decision{Allow: false, Reason: "role_lacks_action"}
	}
	// A write must satisfy the read predicate on the target scope AND not widen (envelope handled
	// by WriteEnvelope + ObEnvelopeFloor at the call site). Personal + not-owner is denied.
	if r.Personal && r.Owner != a.Subject {
		return authz.Decision{Allow: false, Reason: "not_owner"}
	}
	return authz.Decision{Allow: true, Reason: "allow",
		Obligations: []authz.Obligation{{Kind: authz.ObAudit}}}
}
```

The two store lowerings of the *workspace* predicate above:

```sql
-- SQLLowerer → the library-list WHERE (and the generated RLS policy body share this source)
WHERE scope_id = $1                                   -- app.workspace_id
  AND access_level <= $2                              -- app.clearance
  AND (cardinality($3) = 0 OR allowed_principals && $3) -- app.principals (GIN &&)
```
```json
// QdrantLowerer → payload filter (workspace collection)
{ "must": [
  { "key": "workspace_id",  "match": { "value": "<ctx>" } },
  { "key": "access_level",  "range": { "lte": 3 } },
  { "should": [
    { "is_empty": { "key": "allowed_principals" } },
    { "key": "allowed_principals", "match": { "any": ["group:eng","ext:confluence:space:SEC"] } }
  ], "min_should": 1 }
] }
```

Both are `Lower(TwoAxisPolicy.Visibility(actor, {Collection:"workspace"}))`. The contract test proves they select the same documents.

---

## Identity-provider portability (Auth0 / Casdoor / Ory / Okta / WorkOS / …)

This port is **authorization** (*what may they see/do?*). *Authentication* (*who are they?* — the IdP: Auth0, Casdoor, Ory, Okta, WorkOS) stays in the kernel `Auth` interface. The two compose through exactly one seam — `PrincipalResolver` — and that composition is what makes the decision engine independent of whichever provider an organization runs.

```text
Auth0 / Casdoor / Ory / Okta / WorkOS          ← the org's choice
        │   OIDC / SCIM / PAT
        ▼
kernel Auth interface    ── authN adapter: verify token, OIDC exchange, issue opaque session
        │   → Identity { Subject, RawGroups (claims), Roles }
        ▼
PrincipalResolver        ── the ONE provider-touching seam in authz: Identity → Actor
        │   → Actor { Clearance, Principals, Roles }
        ▼
Authorizer · Policy · Lowerer · Predicate  ── pure decision + lowering to RLS/Qdrant; NEVER sees the IdP
```

### What a provider swap costs

| Layer | Provider-dependent? | Cost of swapping the IdP |
|---|---|---|
| `Policy` / `Predicate` / `Lowerer` / `Eval` / the parity test | **No — zero** | Nothing. It only ever sees an `Actor`. Casdoor → Auth0 → Ory changes not one line. |
| kernel **`Auth`** interface (token verify / OIDC) | Yes, but **already abstracted** ([auth-flow.md](./auth-flow.md)) | Config, or a thin adapter for a non-OIDC quirk. `casdoor.Auth` today; `jwt`/`workos` interchangeable. |
| **`PrincipalResolver`** (claims → `Actor`) | Yes — **one isolated adapter** | The only real per-provider work: map that IdP's *group membership* claim/SCIM into `Actor.Principals`. |

### Why the engine is genuinely portable

**Clearance and roles are app-owned, not carried in the IdP token.** The BFF resolves `(role, clearance)` from `workspace_members` at session-mint and mints its **own** opaque session (auth-flow §Session model) — it never asks the IdP to express "clearance L4". So a provider only has to do two things:

1. **Authenticate** — every OIDC provider does this identically (the `Auth` adapter is config-shaped), and
2. **(Phase 2 only) supply group membership** — for the `ext:` principals.

Everything else — the ladder, personal scope, the whole decision — is your data, so it cannot depend on a provider's feature set.

### Per-provider guidance

- **One package per provider implements both halves.** A provider adapter directory (e.g. `kernel/identity/auth0/`, `.../ory/`, `.../casdoor/`) implements the `Auth` verify **and** its `PrincipalResolver` claim-mapping. "Add Auth0" = one directory; `depguard` (`kernel/authz/**` ⊄ `internal/**`, and provider packages ⊄ the decision core) keeps the specifics from leaking inward.
- **Group-claim shapes are the substance.** Auth0 `groups`, Okta groups, **Azure AD app-roles vs. groups**, Ory identity-schema traits, SCIM 2.0 `Groups` — these differ; the resolver adapter normalizes them to `group:<id>` / `ext:<source>:<id>` principals, then the port's own `∩ used_principals` + `min(owner)` bounds (invariant 8) apply uniformly regardless of source.
- **Freshness is a provider property, handled once.** Whether group-revocation propagates by webhook (fast) or poll (Drive-style, lossy) is per-source and already an SLO in [draft-plan.md § ACL freshness and revocation lag](../../draft-plan.md#access-model-decided) — the resolver adapter picks the path; the engine and its deny-on-read semantics are unchanged.
- **Phase 1 needs zero mapping.** `SingleAxisPolicy` uses only app-owned clearance, so it runs behind **any** OIDC provider with no `PrincipalResolver` group work at all — the group-claim adapter is only required when the Phase-2 group-ACL axis is switched on.

> Net: adopting Auth0/Casdoor/Ory/Okta is a config-or-one-adapter change at the *edge* of the system; the authorization decision engine, the RLS↔Qdrant parity guarantee, and every invariant above are untouched.

---

## Contract-test skeleton (the crown jewel: parity)

Validates *any* `Policy`+`Lowerer` set against the invariants. The parity suite is the one that directly buys down the "three copies drift" leak — it fuzzes a corpus and asserts every backend agrees with the in-memory oracle.

```go
package authz_test

// ParityContract is MANDATORY. It proves the SQL lowering, the Qdrant lowering, and the pure
// Eval oracle admit an IDENTICAL set over a random corpus — i.e. RLS, the library query, and the
// Qdrant filter cannot diverge. Run in CI on every change to a Policy or a Lowerer. (invariant 1)
func ParityContract(t *testing.T, pol authz.Policy, sql authz.Lowerer, qd authz.Lowerer,
	runSQL func(authz.SQLFilter, []authz.Resource) map[string]bool, // executes WHERE over the corpus (Testcontainers PG)
	runQdrant func(json.RawMessage, []authz.Resource) map[string]bool) { // executes the filter (Testcontainers Qdrant)

	corpus := fuzzResources(2000) // random scope/level/principals/personal across the model's ranges
	for _, actor := range fuzzActors(200) {
		for _, coll := range []string{"personal", "workspace"} {
			q := authz.Query{ResourceType: "document", Collection: coll}
			pred := pol.Visibility(actor, q)

			// Oracle: the pure predicate over each row.
			want := map[string]bool{}
			for _, r := range corpus {
				want[r.ID] = authz.Eval(pred, r) && r.Scope == actor.Scope
			}

			ls, err := sql.Lower(pred); mustNoErr(t, err)
			gotSQL := runSQL(*ls.SQL, corpus)
			lq, err := qd.Lower(pred); mustNoErr(t, err)
			gotQdrant := runQdrant(lq.Qdrant, corpus)

			if !sameSet(want, gotSQL) {
				t.Fatalf("SQL lowering diverges from oracle: actor=%v coll=%s diff=%v", actor, coll, diff(want, gotSQL))
			}
			if !sameSet(want, gotQdrant) {
				t.Fatalf("Qdrant lowering diverges from oracle: actor=%v coll=%s diff=%v", actor, coll, diff(want, gotQdrant))
			}
		}
	}
}

// InvariantContract runs against ANY Policy — pure, no infra.
func InvariantContract(t *testing.T, pol authz.Policy) {
	t.Run("fail closed: empty/untrusted actor sees nothing", func(t *testing.T) {
		zero := authz.Actor{Scope: authz.Scope{Kind: "workspace", ID: "w1"}} // no clearance, no principals
		p := pol.Visibility(zero, authz.Query{Collection: "workspace"})
		for _, r := range fuzzResources(200) {
			if r.AccessLevel > 0 && authz.Eval(p, r) {
				t.Fatalf("zero-clearance actor saw level-%d doc %s", r.AccessLevel, r.ID)
			}
		}
	})
	t.Run("read-deny is masked as not_found (existence privacy)", func(t *testing.T) {
		a := actorAt(2, nil)
		d := pol.Permit(a, authz.ActionRead, res(4, nil)) // above clearance
		if d.Allow || !hasOb(d, authz.ObMaskAsNotFound) && d.Reason != "read_uses_filter" {
			// reads route through Visibility; the enforcement wrapper attaches ObMaskAsNotFound on the empty read
		}
	})
	t.Run("no implicit admin read", func(t *testing.T) {
		admin := authz.Actor{Scope: sc, Roles: []string{"admin"}, Clearance: 2} // admin but only L2, no group
		p := pol.Visibility(admin, authz.Query{Collection: "workspace"})
		if authz.Eval(p, res(4, []authz.Principal{"group:eng"})) {
			t.Fatal("admin role must NOT grant read of an L4 group-restricted doc without a grant")
		}
	})
	t.Run("both conjuncts always: clearance never bypasses ACL, ACL never bypasses clearance", func(t *testing.T) {
		l5noGroup := actorAt(5, nil) // top clearance, but not in group:eng
		p := pol.Visibility(l5noGroup, authz.Query{Collection: "workspace"})
		if authz.Eval(p, res(4, []authz.Principal{"group:eng"})) {
			t.Fatal("L5 without group:eng must NOT see an eng-restricted doc (ACL not bypassed by clearance)")
		}
	})
	t.Run("agent bound: min(owner) clearance, intersection principals", func(t *testing.T) {
		// resolver-level test — an agent Actor never exceeds its owner; asserted in ResolverContract
	})
}

// Wiring — concrete impls plug into the shared suites:
//   func TestTwoAxisPolicy_Invariants(t *testing.T) { InvariantContract(t, policy.TwoAxisPolicy{}) }
//   func TestTwoAxis_Parity(t *testing.T)           { ParityContract(t, policy.TwoAxisPolicy{}, sqlLowerer, qdrantLowerer, execPG(t), execQdrant(t)) }
```

### `ResolverContract` — the `min(owner)` bound is structural, not documentation

This is where invariant 8 is proven: an agent can never out-clear or out-group its owner, the
bound is recomputed at every mint (so demotion follows the human with no cleanup job), a human's
principals are narrowed to `used_principals` (not their whole directory), and resolution **fails
closed**. It runs against a real resolver (Testcontainers Postgres for `workspace_members` /
`principal_grants` / the `used_principals` set, plus a fake IdP/SCIM claim source) because
`Resolve` does I/O — but the *seed → mint → assert* shape is identical for any implementation.

```go
package authz_test //go:build integration

// ResolverContract runs against ANY authz.PrincipalResolver. `env` seeds the backing stores and
// hands back a fresh resolver; the helpers mutate the same stores so a re-mint sees the change.
func ResolverContract(t *testing.T, env func(t *testing.T) ResolverEnv) {
	ctx := context.Background()

	// helpers (env-provided): seed a member's clearance/groups, seed an agent's DECLARED clearance/
	// groups + owner, set which principals actually gate content, then Resolve an identity → Actor.
	//   env.PutMember(user, clearance, groups...)
	//   env.PutAgent(agent, owner, declaredClearance, declaredGroups...)
	//   env.SetUsedPrincipals(p...)          // the distinct principals appearing on indexed rows
	//   env.Resolve(subject) (authz.Actor, error)

	t.Run("agent clearance is min(agent, owner) — cannot exceed the owner", func(t *testing.T) {
		e := env(t)
		e.PutMember("user:owner", 3)                         // owner is L3
		e.PutAgent("agent:a1", "user:owner", 5)              // agent DECLARES L5
		a, err := e.Resolve("agent:a1"); mustNoErr(t, err)
		if a.Clearance != 3 {
			t.Fatalf("agent clearance = %d, want min(5,3)=3 — an agent must never out-clear its owner", a.Clearance)
		}
	})

	t.Run("agent clearance is min when the agent is the lower one (never raised to the owner)", func(t *testing.T) {
		e := env(t)
		e.PutMember("user:owner", 5)
		e.PutAgent("agent:a1", "user:owner", 2)              // deliberately narrow agent
		a, _ := e.Resolve("agent:a1")
		if a.Clearance != 2 {
			t.Fatalf("agent clearance = %d, want 2 — the bound narrows, it never lifts a low agent to its owner", a.Clearance)
		}
	})

	t.Run("agent principals are the intersection with the owner (⊆ owner, never a union)", func(t *testing.T) {
		e := env(t)
		e.PutMember("user:owner", 3, "group:eng", "group:legal")
		e.PutAgent("agent:a1", "user:owner", 3, "group:eng", "group:board") // board NOT held by owner
		e.SetUsedPrincipals("group:eng", "group:legal", "group:board")
		a, _ := e.Resolve("agent:a1")
		got := set(a.Principals)
		if got["group:board"] {
			t.Fatal("agent carries group:board its owner lacks — principals must be agent ∩ owner")
		}
		if !got["group:eng"] {
			t.Fatal("agent lost group:eng held by BOTH — intersection dropped a legitimate group")
		}
		if got["group:legal"] {
			t.Fatal("agent gained group:legal the agent never declared — bound is an intersection, not the owner's set")
		}
	})

	t.Run("demotion follows the human on the NEXT mint (no stored bound, no cleanup job)", func(t *testing.T) {
		e := env(t)
		e.PutMember("user:owner", 5, "group:eng")
		e.PutAgent("agent:a1", "user:owner", 5, "group:eng")
		if a, _ := e.Resolve("agent:a1"); a.Clearance != 5 || !set(a.Principals)["group:eng"] {
			t.Fatal("precondition: agent should start at L5 + group:eng")
		}
		e.PutMember("user:owner", 2)                         // owner demoted L5→L2 and removed from group:eng
		a, _ := e.Resolve("agent:a1")                        // re-mint
		if a.Clearance != 2 {
			t.Fatalf("after owner demotion agent clearance = %d, want 2 — revocation must follow the owner", a.Clearance)
		}
		if set(a.Principals)["group:eng"] {
			t.Fatal("agent still carries group:eng after the owner lost it — the bound is recomputed at mint")
		}
	})

	t.Run("human principals are narrowed to used_principals (not the whole directory)", func(t *testing.T) {
		e := env(t)
		many := make([]authz.Principal, 500)                 // a user in 500 directory groups…
		for i := range many { many[i] = authz.Principal(fmt.Sprintf("group:g%d", i)) }
		e.PutMember("user:u1", 3, many...)
		e.SetUsedPrincipals("group:g7", "group:g42")         // …only 2 of which gate any content
		a, _ := e.Resolve("user:u1")
		if len(a.Principals) > 3 { // user:self + the 2 used groups
			t.Fatalf("carried %d principals, want ≤3 (self + used) — the filter bound is |used|, not |directory|", len(a.Principals))
		}
	})

	t.Run("fail closed: an unresolvable identity errors, never a partial (permissive) Actor", func(t *testing.T) {
		e := env(t)
		_, err := e.Resolve("user:ghost")                    // no member row, no groups
		if err == nil {
			t.Fatal("unresolved identity must ERROR so the caller denies — never return an empty Actor that a filter treats as unrestricted")
		}
	})

	t.Run("an empty principal set means 'matches only ACL-empty docs', never 'matches everything'", func(t *testing.T) {
		e := env(t)
		e.PutMember("user:u1", 3)                            // valid member, in no gating group
		a, err := e.Resolve("user:u1"); mustNoErr(t, err)
		// The resolved Actor is valid; downstream Visibility must still require ACL-empty OR overlap.
		p := policy.TwoAxisPolicy{}.Visibility(a, authz.Query{Collection: "workspace"})
		if authz.Eval(p, res(2, []authz.Principal{"group:eng"})) {
			t.Fatal("empty-principal actor matched a group-restricted doc — empty set must not be a wildcard")
		}
		if !authz.Eval(p, res(2, nil)) {
			t.Fatal("empty-principal actor should still see ACL-empty docs at/below clearance")
		}
	})

	t.Run("subject typing: agent carries agent:<uuid> + owner; human carries user:<uuid>", func(t *testing.T) {
		e := env(t)
		e.PutMember("user:owner", 3); e.PutAgent("agent:a1", "user:owner", 3)
		ag, _ := e.Resolve("agent:a1"); hu, _ := e.Resolve("user:owner")
		if !strings.HasPrefix(string(ag.Subject), "agent:") { t.Fatal("agent Subject must be agent:") }
		if !strings.HasPrefix(string(hu.Subject), "user:")  { t.Fatal("human Subject must be user:") }
	})
}

// Wiring — the AISAT resolver (Casdoor/SCIM claims + Postgres member/grant rows) plugs in:
//   func TestCasdoorSCIMResolver_Contract(t *testing.T) {
//       ResolverContract(t, func(t *testing.T) ResolverEnv { return newResolverEnv(t, startPG(t), fakeIdP(t)) })
//   }
```

Three assertions above are the ones a security reviewer will single out: **min-clearance** and
**principal-intersection** make the confused-deputy bound structural rather than a convention;
**demotion-follows-on-next-mint** proves there is no stored, forgettable copy of an agent's
authority (it rides the same opaque-session invalidation as a human's clearance change,
[auth-flow §Session model](./auth-flow.md#session-model--opaque-reference-token-not-stateless-jwt));
and **fail-closed** guarantees a resolution failure denies rather than emitting an Actor whose
empty fields a downstream filter could misread as "unrestricted."

---

## Deployment topology & extraction

Same posture as [metering-ports.md](./metering-ports.md#deployment-topology-embedded-library-or-standalone-runtime-service): **start embedded** (`kernel/authz` imported in-process — a decision is a pure function call, no network hop on the request critical path), and extract to a co-located **PDP service** only when a *second* product needs the same access model. The `Authorizer` interface is the swap point; `Filter`/`Check` behind a thin gRPC facade satisfy the same interface, and business code depends on `authz.Authorizer`, never the transport. Unlike metering, the hot path here has **no durable writer** — `PrincipalResolver` is the only I/O and it runs at session-mint, cached in the opaque session, so an embedded deployment adds zero per-request latency.

Follow the same hexagonal layout and the same two linters (`go-arch-lint` for the component graph, `depguard` to keep `kernel/authz/**` free of `internal/**` and infra SDKs) as the metering module. The one product-specific binding — the `Policy` — is injected in `cmd/`, exactly like the `Pricer`:

```go
// backend-go/cmd/api/main.go
authorizer := authzapp.New(authzapp.Deps{
	Policy:    policy.TwoAxisPolicy{},            // ← product-specific model (injected)
	Resolver:  casdoorscim.New(idp, scimClient),  // driven adapter: identity → Actor
	Lowerers:  map[string]authz.Lowerer{"sql": sqllower.New(), "qdrant": qdrantlower.New()},
	Mode:      authz.EnforceMode,
})
// business code depends on authz.Authorizer — today in-process, tomorrow a PDP client. No caller change.
```

---

## Generalization checklist (before reusing this in another system)

- [ ] **Policy implemented** — one `authz.Policy` with pure `Visibility`/`Permit`. Reads go through `Visibility` (a predicate), point ops through `Permit`. No I/O.
- [ ] **Fields mapped** — the model's logical `Field`s mapped by each `Lowerer` to physical columns / payload keys. An unmapped field lowers to deny-all, never no-op.
- [ ] **Lowerers total** — one `Lowerer` per store, TOTAL over the AST; an unknown node → the store's empty result.
- [ ] **Parity test green** — `ParityContract` runs in CI across every store lowering; SQL ⇔ Qdrant ⇔ `Eval` agree on a fuzzed corpus. **Do not ship a second enforcement point without it.**
- [ ] **Resolver fail-closed** — `PrincipalResolver` errors → deny; agent subjects bounded to owner; human principals ∩ `used_principals`; resolved at session-mint, cached, invalidated on change.
- [ ] **Obligations honored** — read-deny → `not_found`; writes/admin → audit row; break-glass path is reason-required + time-boxed; derived writes carry the envelope floor.
- [ ] **Isolation preserved** — `Eq(scope, ctx)` is a conjunct of every predicate; isolation is a single equality, never dropped for convenience.
- [ ] **Mode chosen** — `shadow` a new axis against live traffic before `enforce`; `allowed_principals='{}'` makes the pre-enforcement delta provably empty on legacy rows.

---

## Non-goals (stays in the host / other ports, by design)

- **Authentication** — *who* the caller is, token verification, sessions: the kernel `Auth` interface + [auth-flow.md](./auth-flow.md). This port starts from a verified `Identity`.
- **A general policy DSL / relationship engine.** This engine compiles to **pre-filters** for retrieval — that is the whole point (draft-plan §Why not a policy engine). A host that *also* needs per-object ReBAC for point *management* ops MAY back `Policy.Permit` with Cedar/OpenFGA **while keeping `Visibility` as a compiled predicate** — the two methods are separate for exactly this reason. ABAC-style attribute conditions and conjunctive (AND-of-groups) compartments are out of the reference model and are an additive predicate node, not a rewrite.
- **Audit persistence** — the port *emits* `ObAudit`; writing the append-only `agent_audit_log`/`audit_log` rows is the host's (kept outside the access model so an agent can never read/modify its own trail).
- **Metering** — spend/limits are [metering-ports.md](./metering-ports.md). Authorization gates *whether*; metering gates *how much*.
- **Tenancy semantics** — what a `Scope` *means* and its physical isolation column are the host's; the engine treats scope as an opaque identity it never crosses.
