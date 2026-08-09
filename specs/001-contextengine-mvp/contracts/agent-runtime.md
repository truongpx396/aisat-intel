# Moved: Agent Runtime contract → `intel-agent`

> **This contract now lives in [truongpx396/intel-agent](https://github.com/truongpx396/intel-agent).**
> Canonical source: [specs/001-agent-runtime/contracts/agent-runtime.md](https://github.com/truongpx396/intel-agent/blob/main/specs/001-agent-runtime/contracts/agent-runtime.md)

This file is a **pointer stub**, kept at its original path so existing links keep resolving. It is not maintained.

## Why it moved

This contract specified its own extraction: **Profile B — self-contained single-domain agent (the extraction target)**. The move at [`369756e`](https://github.com/truongpx396/aisat-intel/commit/369756e) realizes it. Commit history travelled with the file.

The profile relationship is unchanged and is the thing to remember when reading anything in this repo about the agent:

- **Profile A** (what this product ships) = **Profile B** + the Go kernel (single `credit_ledger` writer, auth/session, RLS-GUC middleware) + Qdrant and JetStream.
- **Profiles are a superset relation, not a fork.** Both run the same binary and the same manifest schema.
- **The access floor is profile-invariant.** Profile A lowers the visibility predicate to RLS **and** the Qdrant payload filter; Profile B lowers it to RLS alone. Fewer lowerings is fewer copies to keep in parity, not fewer guarantees — SC-001 holds identically.

## What this repo still owns

This product is the reference Profile-A host. Its obligations — stamping `ctx`, enforcing the access floor, metering, moderation, and human gates — are specified in [agent-integration.md](./agent-integration.md) against the runtime's [host-integration.md](https://github.com/truongpx396/intel-agent/blob/main/specs/001-agent-runtime/contracts/host-integration.md).
