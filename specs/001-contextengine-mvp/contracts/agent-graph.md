# Moved: Agent Graph contract → `intel-agent`

> **This contract now lives in [truongpx396/intel-agent](https://github.com/truongpx396/intel-agent).**
> Canonical source: [specs/001-agent-runtime/contracts/agent-graph.md](https://github.com/truongpx396/intel-agent/blob/main/specs/001-agent-runtime/contracts/agent-graph.md)

This file is a **pointer stub**, kept at its original path so the ~19 documents that link here keep resolving. It is not maintained; do not add content to it.

## Why it moved

The agent runtime was extracted at [`369756e`](https://github.com/truongpx396/aisat-intel/commit/369756e) so it can be built independently of this product, per [agent-runtime.md § Profile B — the extraction target](./agent-runtime.md). Full commit history for this contract travelled with it (`git log --follow` in the new repo shows every revision back to its first).

## Deep links

Anchors referenced from elsewhere in this repo, and where they now live:

| Old anchor | Now |
|---|---|
| `#extraction-checklist` | superseded by [host-integration.md](https://github.com/truongpx396/intel-agent/blob/main/specs/001-agent-runtime/contracts/host-integration.md) — the checklist is now a **normative** host contract, not a descriptive list |
| `#tool-access-in-process-impls-one-mcp-server` | [agent-graph.md § Tool access](https://github.com/truongpx396/intel-agent/blob/main/specs/001-agent-runtime/contracts/agent-graph.md#tool-access-a-toolregistry-port-in-process-impls-one-mcp-server-or-a-remote-mcp-client) |
| `#human-in-the-loop-the-human_gate-node-durable-form` | [agent-graph.md § Human-in-the-loop](https://github.com/truongpx396/intel-agent/blob/main/specs/001-agent-runtime/contracts/agent-graph.md#human-in-the-loop-the-human_gate-node-durable-form) |

## What this repo still owns

The graph is consumed here through the ports in [agent-deps.md](https://github.com/truongpx396/intel-agent/blob/main/specs/001-agent-runtime/contracts/agent-deps.md). This product supplies the implementations and re-satisfies the five host obligations — see [agent-integration.md](./agent-integration.md).
