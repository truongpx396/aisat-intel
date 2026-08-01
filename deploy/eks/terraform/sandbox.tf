# ---------------------------------------------------------------------------
# Sandbox Runtime tier — the KVM/bare-metal capacity + control-plane seam for the
# microVM sandbox fleet that runs isolated code/tool execution (crawl4ai fetch,
# MarkItDown convert, and Phase-2 code-gen scripts).
#
# Contract: ../../../specs/001-contextengine-mvp/contracts/sandbox-runtime.md
# Config home: ../../sandbox/
#
# WHY A SEPARATE POOL. Firecracker microVMs require /dev/kvm (hardware
# virtualization). The default app node group (t3.large, nitro) does NOT expose
# nested virt, so the fleet runs on a dedicated *.metal node group — provisioned in
# eks.tf's eks_managed_node_groups under `var.sandbox_enabled`, tainted
# `sandbox=true:NoSchedule` so only sandbox VMs land there (same blast-radius +
# resource-divergence rationale the README gives for peeling out the crawl worker,
# now hardware-enforced and reused by convert + code-gen).
#
# WHERE KVM IS UNAVAILABLE. If bare-metal is too costly, keep var.sandbox_enabled
# = false and run the fleet with a gVisor/runsc backend (SANDBOX_KIND=daytona) on
# the normal app nodes — a per-environment isolation choice behind the same Sandbox
# port, not an app change.
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
