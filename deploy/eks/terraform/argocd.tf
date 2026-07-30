# ---------------------------------------------------------------------------
# Argo CD — GitOps controller, installed via the official argo-helm chart into
# var.argocd_namespace. Bootstrap-only here: it just gets Argo CD running. Point
# it at Applications (this repo ships an app-of-apps under deploy/eks/argocd/) to
# have it manage the observability stack via Git instead of Terraform.
#
#   # first-login admin password (username: admin):
#   kubectl -n argocd get secret argocd-initial-admin-secret \
#     -o jsonpath='{.data.password}' | base64 -d; echo
#   kubectl -n argocd port-forward svc/argocd-server 8080:443   # https://localhost:8080
# ---------------------------------------------------------------------------
resource "kubernetes_namespace" "argocd" {
  count = var.enable_argocd ? 1 : 0

  metadata {
    name = var.argocd_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "argocd" {
  count = var.enable_argocd ? 1 : 0

  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_version
  namespace  = var.argocd_namespace

  timeout = 600
  atomic  = true
  wait    = true

  values = [
    templatefile("${path.module}/values/argocd.yaml.tftpl", {
      argocd_domain = var.argocd_domain
    })
  ]

  depends_on = [kubernetes_namespace.argocd]
}
