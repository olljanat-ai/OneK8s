# Guardrails: assign the built-in "Kubernetes cluster pod security baseline
# standards for Linux-based workloads" initiative to the resource group.
#
# The assignment on its own reports nothing: the effect is evaluated by
# Gatekeeper, which reaches the cluster as the Azure Policy add-on
# (var.aks_azure_policy_enabled, aks.tf). Assigned without the add-on, this is
# a compliance record that stays permanently empty.
#
# No AVM module covers a resource-group policy assignment, so it stays a
# provider resource.
resource "azurerm_resource_group_policy_assignment" "aks_baseline" {
  count = var.enable_baseline_policy ? 1 : 0

  name                 = "aks-pod-security-baseline"
  resource_group_id    = module.resource_group.resource_id
  policy_definition_id = "/providers/Microsoft.Authorization/policySetDefinitions/a8640138-9b0a-4a28-b8cb-1666c838647d"

  parameters = jsonencode({
    effect = { value = var.baseline_policy_effect }
  })
}
