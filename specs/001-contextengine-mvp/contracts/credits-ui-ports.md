# Contract: Credits & Billing UI — **binding to `intel-payment`**

**Plan**: [../plan.md](../plan.md) | **Status**: Pointer + binding. The package now lives upstream.

> ### The design moved
> The `credits-ui` package designed here — `CreditsSource`, `LimitView`, `UnitLabels`,
> `LedgerColumn`, `BreakdownSeries`, `BillingAnchor`, `PlanCatalog`, `CheckoutSource`, and the
> invariants that keep a money screen honest — is now part of an independent project:
>
> ### 📦 **[truongpx396/intel-payment](https://github.com/truongpx396/intel-payment)**
> **Canonical contract**: [`specs/001-metering-billing-core/contracts/credits-ui-ports.md`](https://github.com/truongpx396/intel-payment/blob/main/specs/001-metering-billing-core/contracts/credits-ui-ports.md)
>
> Its git history came across intact. That repository is **authoritative** for the package; this
> file records only how ContextEngine *binds* to it.

---

## What ContextEngine supplies

```typescript
// frontend/src/features/credits/ — every product specific lives here.
const labels: UnitLabels = { unit: "credits", one: "credit", abbr: "cr" };

const columns: LedgerColumn[] = [
  { key: "model",  header: "Model",  accepts: r => "model" in r.attributes,
    render: r => <Mono>{r.attributes.model as string}</Mono> },
  { key: "tokens", header: "Tokens", align: "end",
    accepts: r => "tokens" in r.attributes,
    render: r => <Mono>{fmt(r.attributes.tokens as number)}</Mono> },
];

<CreditsPanel
  source={new BffCreditsSource("/credits")}
  scope={{ realm: "aisat-intel", kind: "workspace", id: workspaceId }}
  labels={labels}
  columns={columns}
  billing={{ planCard: <OrgPlanPointer/> }}   // billing anchors to the organization (Phase 2)
/>
```

| Binding | ContextEngine's value |
|---|---|
| `UnitLabels` | "credits" |
| `LedgerColumn[]` | `model`, `tokens` — LLM-specific, registered rather than built in |
| `BreakdownSeries[]` | `query` · `ingest` · `caption` · `rerank` |
| `BillingAnchor` | the **organization** (Phase 2) — the workspace holds an allocation, not a plan ([organization.md](../../../design-system/aisat-intel/pages/organization.md)) |
| `CreditsSource` | `GET /credits` via the BFF ([bff-rest.md](./bff-rest.md)) |
| Ceiling count | **three** — and it is data, so the panel renders whatever `[]Limit` returns |

Screen spec and the normative don'ts: [pages/credits.md](../../../design-system/aisat-intel/pages/credits.md).

## The wire shape this requires

`GET /credits` must return the full `CreditsSnapshot`, not just `{ balance, warning_threshold_pct,
near_limit }`. The `limits[]` array is the load-bearing field: it is what makes the ceiling panel
generic instead of three hardcoded cards, and the kernel already holds the data in that shape. See
the upstream contract for the full field list and
[rest-api.md](https://github.com/truongpx396/intel-payment/blob/main/specs/001-metering-billing-core/contracts/rest-api.md)
for the canonical endpoint.

Two upstream additions worth adopting when this screen is built:

- **`GET /v1/fulfilment`** — the only honest source of "credits arrived". The panel must render
  *processing* on return from checkout and never infer a grant from a redirect.
- **Member-scoped breakdown** — self-only unless the viewer holds the admin entitlement. A credits
  screen that shows colleagues' usage is a privacy leak wearing a billing label.
