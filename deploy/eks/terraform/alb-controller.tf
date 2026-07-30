# AWS Load Balancer Controller — installed via Helm so the chart's Ingress
# (ingressClassName: alb) provisions a real internet-facing ALB with ACM TLS.
#
# The controller's ServiceAccount is annotated with the IRSA role from irsa.tf.
# Skipped if var.install_alb_controller = false (e.g. you manage it out of band).
resource "helm_release" "aws_load_balancer_controller" {
  count = var.install_alb_controller ? 1 : 0

  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.8.2"
  namespace  = "kube-system"

  # Wait for the node group before the controller schedules.
  depends_on = [module.eks]

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.alb_controller_irsa.iam_role_arn
  }
}
