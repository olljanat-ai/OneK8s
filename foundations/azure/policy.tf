# Guardrails: assign the built-in "Kubernetes cluster pod security baseline
# standards for Linux-based workloads" initiative in audit mode. Flip to
# "deny" per environment once workloads are compliant.
resource "azurerm_resource_group_policy_assignment" "aks_baseline" {
  count = var.enable_baseline_policy ? 1 : 0

  name                 = "aks-pod-security-baseline"
  resource_group_id    = azurerm_resource_group.this.id
  policy_definition_id = "/providers/Microsoft.Authorization/policySetDefinitions/a8640138-9b0a-4a28-b8cb-1666c838647d"

  parameters = jsonencode({
    effect = { value = "audit" }
  })
}
