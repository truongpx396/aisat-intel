# Moved: Approval Ports contract → `intel-agent`

> **This contract now lives in [truongpx396/intel-agent](https://github.com/truongpx396/intel-agent).**
> Canonical source: [specs/001-agent-runtime/contracts/approval-ports.md](https://github.com/truongpx396/intel-agent/blob/main/specs/001-agent-runtime/contracts/approval-ports.md)

This file is a **pointer stub**, kept at its original path so existing links keep resolving. It is not maintained.

## Why it moved

The `human_gate` node is a graph node, and the `HumanGate`/`ApprovalStore` ports are how it reaches durable storage. The ports travelled with the graph at [`369756e`](https://github.com/truongpx396/aisat-intel/commit/369756e).

## The one thing that did NOT move

**The `approval_request` table stays in this repo**, because it is a kernel table that also backs non-agent gates — the ingestion `enrich_accept` and `sensitivity_confirm` flows have nothing to do with the agent runtime.

So: intel-agent defines the `ApprovalStore` **port** and ships a reference implementation for its standalone profile; this repo owns the **table** and binds it to that port. This is the clearest instance of the general rule — *the port is theirs, the implementation and the deployment are ours* — and the reason the split is not simply "everything approval-shaped moves".

Consequently, `ApprovalContract` (in [`intel_agent.conformance`](https://github.com/truongpx396/intel-agent/blob/main/src/intel_agent/conformance/__init__.py)) runs in **this** repo's CI against **this** repo's implementation. See [agent-integration.md](./agent-integration.md).
