# Moved: MCP Tools contract → `intel-agent`

> **This contract now lives in [truongpx396/intel-agent](https://github.com/truongpx396/intel-agent).**
> Canonical source: [specs/001-agent-runtime/contracts/mcp-tools.md](https://github.com/truongpx396/intel-agent/blob/main/specs/001-agent-runtime/contracts/mcp-tools.md)

This file is a **pointer stub**, kept at its original path so existing links keep resolving. It is not maintained.

## Why it moved

The tool catalog and its allowlist dispatch are part of the agent runtime, reached through the `ToolRegistry` port. Extracted at [`369756e`](https://github.com/truongpx396/aisat-intel/commit/369756e) with full history.

## The split, precisely

This is the contract where the ownership rule matters most, so it is worth stating plainly:

| | Owner |
|---|---|
| The `ToolRegistry` **port**, the dispatch wrapper, the allowlist rule, the audit obligation | **intel-agent** |
| The **tool bodies** for this product's domain, and the `SingleAxisPolicy` they run under | **aisat-intel** (this repo, as a `DomainPlugin`) |

A tool body is domain code. The enforcement around it is not. That is why the wrapper travelled and the bodies did not.

## What this repo still owns

This product's `DomainPlugin` — its tool implementations plus its `Policy` — plus the deployment of any MCP server exposing them outward. See [agent-integration.md](./agent-integration.md).
