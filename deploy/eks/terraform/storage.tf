# gp3 StorageClass — the class every PVC in the repo references (the app chart's
# StatefulSets and the monitoring/Langfuse PVCs). EKS ships a default `gp2`
# class; the EBS CSI addon does NOT create a gp3 one, so we do it here.
#
# Not marked default (to avoid two default classes alongside gp2) — PVCs name it
# explicitly. WaitForFirstConsumer defers binding until a pod schedules, so the
# volume lands in the pod's AZ.
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type      = "gp3"
    fsType    = "ext4"
    encrypted = "true"
  }

  depends_on = [module.eks]
}
