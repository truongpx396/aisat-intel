# ---------------------------------------------------------------------------
# In-cluster observability, installed via Helm right after the cluster exists:
#   - kube-prometheus-stack : Prometheus (Operator) + Alertmanager + Grafana +
#                             node-exporter + kube-state-metrics
#   - loki                  : log store (SingleBinary, filesystem)
#   - tempo                 : trace store (OTLP in on 4317/4318)
#
# All land in var.monitoring_namespace. Grafana is pre-wired with Loki + Tempo
# datasources (see values/kube-prometheus-stack.yaml.tftpl).
#
# Chart versions are pinned via variables. IMPORTANT: `terraform validate` does
# NOT fetch charts, so a stale/wrong pin only surfaces at apply — verify the
# defaults against the upstream chart index (Dependabot maintains them).
# ---------------------------------------------------------------------------
resource "kubernetes_namespace" "monitoring" {
  count = (var.enable_kube_prometheus_stack || var.enable_loki || var.enable_tempo) ? 1 : 0

  metadata {
    name = var.monitoring_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "kube_prometheus_stack" {
  count = var.enable_kube_prometheus_stack ? 1 : 0

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_version
  namespace  = var.monitoring_namespace

  # CRDs are large; give the install room and let Helm wait for readiness.
  timeout       = 900
  atomic        = true
  wait          = true
  wait_for_jobs = true

  values = [
    templatefile("${path.module}/values/kube-prometheus-stack.yaml.tftpl", {
      storage_class        = var.monitoring_storage_class
      monitoring_namespace = var.monitoring_namespace
    })
  ]

  set_sensitive {
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }

  depends_on = [kubernetes_namespace.monitoring, kubernetes_storage_class.gp3]
}

resource "helm_release" "loki" {
  count = var.enable_loki ? 1 : 0

  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.loki_version
  namespace  = var.monitoring_namespace

  timeout = 600
  atomic  = true
  wait    = true

  values = [
    templatefile("${path.module}/values/loki.yaml.tftpl", {
      storage_class = var.monitoring_storage_class
    })
  ]

  depends_on = [kubernetes_namespace.monitoring, kubernetes_storage_class.gp3]
}

resource "helm_release" "tempo" {
  count = var.enable_tempo ? 1 : 0

  name       = "tempo"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"
  version    = var.tempo_version
  namespace  = var.monitoring_namespace

  timeout = 600
  atomic  = true
  wait    = true

  values = [
    templatefile("${path.module}/values/tempo.yaml.tftpl", {
      storage_class = var.monitoring_storage_class
    })
  ]

  depends_on = [kubernetes_namespace.monitoring, kubernetes_storage_class.gp3]
}
