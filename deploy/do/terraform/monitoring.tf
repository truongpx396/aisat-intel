# Optional droplet health alerts, emailed to alert_email.
resource "digitalocean_monitor_alert" "cpu" {
  count       = var.enable_monitoring_alerts ? 1 : 0
  description = "[${var.project_name}] CPU > 80% for 5m"
  type        = "v1/insights/droplet/cpu"
  compare     = "GreaterThan"
  value       = 80
  window      = "5m"
  enabled     = true
  entities    = [digitalocean_droplet.web.id]
  alerts {
    email = [var.alert_email]
  }
}

resource "digitalocean_monitor_alert" "memory" {
  count       = var.enable_monitoring_alerts ? 1 : 0
  description = "[${var.project_name}] Memory > 85% for 5m"
  type        = "v1/insights/droplet/memory_utilization_percent"
  compare     = "GreaterThan"
  value       = 85
  window      = "5m"
  enabled     = true
  entities    = [digitalocean_droplet.web.id]
  alerts {
    email = [var.alert_email]
  }
}

resource "digitalocean_monitor_alert" "disk" {
  count       = var.enable_monitoring_alerts ? 1 : 0
  description = "[${var.project_name}] Disk > 85% for 5m"
  type        = "v1/insights/droplet/disk_utilization_percent"
  compare     = "GreaterThan"
  value       = 85
  window      = "5m"
  enabled     = true
  entities    = [digitalocean_droplet.web.id]
  alerts {
    email = [var.alert_email]
  }
}
