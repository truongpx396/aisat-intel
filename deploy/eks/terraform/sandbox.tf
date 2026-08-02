# ---------------------------------------------------------------------------
# Sandbox Runtime tier — the KVM/bare-metal capacity + control-plane seam for the
# microVM sandbox fleet that runs isolated code/tool execution (crawl4ai fetch,
# MarkItDown convert, and Phase-2 code-gen scripts).
#
# Contract: ../../../specs/001-contextengine-mvp/contracts/sandbox-runtime.md
# Config home: ../../sandbox/
#
# NOT PROVISIONED IN PHASE 1 — var.sandbox_enabled defaults to FALSE, and nothing
# in this file costs anything until it is flipped. Read that as the design intent,
# not as an oversight.
#
# WHY THIS POOL EXISTS AT ALL. Firecracker microVMs require /dev/kvm (hardware
# virtualization). The default app node group (t3.large, nitro) does NOT expose
# nested virt, so a self-hosted microVM fleet needs a dedicated *.metal node group —
# provisioned in eks.tf's eks_managed_node_groups under `var.sandbox_enabled`,
# tainted `sandbox=true:NoSchedule` so only sandbox VMs land there.
#
# WHY IT IS OFF. The smallest x86 *.metal SKU is a standing cost on the order of
# $3k/month. The Phase-1 sandbox workloads are crawl (low-volume, member-initiated,
# public https, HITL-gated) and convert — neither justifies that. Phase 1 therefore
# runs SANDBOX_KIND=k8s_pod: hardened sandbox pods on the normal app nodes, at
# $0 incremental, carrying the identical security contract (no ambient credentials,
# default-deny egress, hard caps, metered, audited). See research §24 for the full
# cost comparison and the rejected alternatives.
#
# WHEN TO TURN IT ON. Possibly NEVER. tmpl-coderun — once assumed to require a
# microVM — lands on gVisor (runtime=runsc) + max_runs=1 on the ordinary k8s_pod
# path instead: gVisor's designed purpose IS untrusted code, and Google runs
# multi-tenant customer code on it. So NO Phase-1 or Phase-2 workload needs
# /dev/kvm. Provision this pool only if the threat model changes — third-party-
# authored code, hostile tenants, or a compliance rule naming hardware isolation.
# The ratchet before that point is
# SANDBOX_RUNTIME=runsc (gVisor) for tmpl-convert — an orthogonal runtime flag on the
# existing k8s_pod path (runtimeClassName: gvisor), not a different backend. It needs
# no /dev/kvm, so it runs on the existing pool for free. If microVMs are needed sooner, two escapes
# avoid this cost: SANDBOX_KIND=e2b_cloud (usage-billed, no floor) or the same
# Firecracker fleet on third-party bare metal (Hetzner/OVH, ~1/40th the AWS price).
# All of it is a per-environment choice behind the same Sandbox port, not an app
# change — which is the whole point of the port.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Self-hosted control-plane seam (installed on top of the node group above).
# The E2B self-host stack (e2b-dev/infra) is Terraform + Nomad + Consul, not
# Kubernetes-native, so on EKS the pragmatic path is a k8s-native backend
# (Daytona / gVisor) deployed via ArgoCD, pinned to the tainted sandbox pool:
#
#   deploy/eks/argocd/apps/sandbox.yaml   ← Application (chart) with
#     nodeSelector: { role: sandbox }
#     tolerations:  [{ key: sandbox, operator: Equal, value: "true", effect: NoSchedule }]
#
# Kept as an out-of-band ArgoCD app (not a helm_release here) so this Terraform
# stays provider-light and the fleet lifecycle is GitOps-managed like the rest of
# the platform (see deploy/eks/argocd/). Uncomment/add the Application when the
# backend is chosen.
# ---------------------------------------------------------------------------

output "sandbox_pool_enabled" {
  description = "Whether the dedicated KVM/bare-metal sandbox node group is provisioned."
  value       = var.sandbox_enabled
}

output "sandbox_node_group" {
  description = "The sandbox managed node group (null unless var.sandbox_enabled)."
  value       = try(module.eks.eks_managed_node_groups["sandbox"].node_group_id, null)
}
