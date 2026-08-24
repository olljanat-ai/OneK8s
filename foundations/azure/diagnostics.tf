# Azure-native diagnostics: one Log Analytics workspace per environment, and
# the diagnostic settings that point the cluster and the vault at it.
#
# This is deliberately *not* a second copy of the observability story. Grafana
# Cloud (monitoring.tf) collects what runs **inside** the cluster — pod
# metrics, logs and events — on all four clouds through one chart. What this
# workspace holds is the part no in-cluster collector can see: the AKS control
# plane's own logs (kube-apiserver, the audit trail, the controller manager)
# and Key Vault's audit events. On a cluster nobody is allowed to lose the
# audit trail of, those are the logs an investigation actually starts from, and
# they only exist as Azure diagnostic settings. (The SQL logical server has
# none: Azure exposes diagnostic categories on databases, not on the server.)
#
# It is also what Microsoft Defender for Containers reports into, which is why
# var.enable_defender is gated on this being on.
locals {
  log_analytics_enabled = var.enable_log_analytics

  log_analytics_workspace_id = one(module.log_analytics_workspace[*].resource_id)

  # Every resource that can emit diagnostics gets the same shape, so turning
  # the workspace off empties the map instead of touching each module.
  diagnostic_settings = local.log_analytics_enabled ? {
    to-log-analytics = {
      name                  = "diag-to-log-analytics"
      workspace_resource_id = local.log_analytics_workspace_id
    }
  } : {}

  # The cluster is the one resource whose categories are chosen rather than
  # taken wholesale. "allLogs" on an AKS control plane means kube-audit, which
  # is every API call every controller makes — a cost item measured in
  # gigabytes a day on a busy cluster, and almost entirely duplicated by
  # kube-audit-admin (the same trail with the read verbs dropped).
  aks_diagnostic_settings = local.log_analytics_enabled ? {
    to-log-analytics = {
      name                  = "diag-to-log-analytics"
      workspace_resource_id = local.log_analytics_workspace_id
      log_groups            = []
      log_categories        = var.aks_diagnostic_log_categories
    }
  } : {}
}

module "log_analytics_workspace" {
  source  = "Azure/avm-res-operationalinsights-workspace/azurerm"
  version = "0.5.1"
  count   = local.log_analytics_enabled ? 1 : 0

  name                = "log-${local.name}"
  location            = var.location
  resource_group_name = module.resource_group.name
  enable_telemetry    = var.enable_telemetry
  tags                = local.tags

  log_analytics_workspace_sku               = var.log_analytics_sku
  log_analytics_workspace_retention_in_days = var.log_analytics_retention_days

  # Null means "no cap", which is the right answer for an audit trail that has
  # to be complete. An environment that would rather drop logs than be
  # surprised by a bill sets a ceiling here; ingestion stops for the rest of
  # the day once it is hit.
  log_analytics_workspace_daily_quota_gb = var.log_analytics_daily_quota_gb

  # Entra-only ingestion and query: the workspace's shared keys are the one
  # credential in this stack that would otherwise grant a reader everything the
  # audit trail holds.
  log_analytics_workspace_local_authentication_enabled = false
}
