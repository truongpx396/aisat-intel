# ---------------------------------------------------------------------------
# Langfuse (v2) — LLM tracing/eval, installed via the official langfuse-k8s chart
# into var.langfuse_namespace with a bundled Postgres. The app tiers point at it
# with LANGFUSE_HOST=http://langfuse-web.<ns>.svc:3000 plus the public/secret
# keys created in the UI (or pre-seeded via LANGFUSE_INIT_* — see the values file).
#
# Secrets (nextauth secret, salt, db password) are injected via set_sensitive so
# nothing sensitive lands in the values file. Verify chart key names against the
# pinned var.langfuse_version.
# ---------------------------------------------------------------------------
resource "kubernetes_namespace" "langfuse" {
  count = var.enable_langfuse ? 1 : 0

  metadata {
    name = var.langfuse_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "langfuse" {
  count = var.enable_langfuse ? 1 : 0

  name       = "langfuse"
  repository = "https://langfuse.github.io/langfuse-k8s"
  chart      = "langfuse"
  version    = var.langfuse_version
  namespace  = var.langfuse_namespace

  timeout = 600
  atomic  = true
  wait    = true

  values = [
    templatefile("${path.module}/values/langfuse.yaml.tftpl", {
      storage_class = var.monitoring_storage_class
    })
  ]

  set_sensitive {
    name  = "langfuse.nextauth.secret"
    value = var.langfuse_nextauth_secret
  }
  set_sensitive {
    name  = "langfuse.salt"
    value = var.langfuse_salt
  }
  set_sensitive {
    name  = "postgresql.auth.password"
    value = var.langfuse_postgres_password
  }

  depends_on = [kubernetes_namespace.langfuse, kubernetes_storage_class.gp3]
}
