# The Secret's data is sensitive as a whole, so everything derived from it
# inherits that mark. Two of the four values are not actually secret — an API
# server address and the CA certificate that identifies it are published by
# every other foundation as plain outputs — and they are unmarked here so the
# stacks reading them can keep publishing them the same way. The client
# certificate and key (and a token, if the kubeconfig carries one instead) stay
# sensitive: those are the credential.
#
# The try() around each nonsensitive() is for the day a provider version stops
# marking that attribute sensitive: unmarking an unmarked value is itself an
# error, and this module has no business failing over it.
output "host" {
  description = "API server URL of the workload cluster (a complete https URL, as EKS and OKE publish)."
  value       = try(nonsensitive(local.cluster["server"]), local.cluster["server"])
}

output "cluster_ca_certificate" {
  description = "Base64-encoded CA certificate of the workload cluster's API server."
  value       = try(nonsensitive(local.cluster["certificate-authority-data"]), local.cluster["certificate-authority-data"])
}

output "client_certificate" {
  description = "Base64-encoded client certificate from the kubeconfig, null when it authenticates with a token instead."
  value       = local.client_certificate
  sensitive   = true
}

output "client_key" {
  description = "Base64-encoded client key from the kubeconfig, null when it authenticates with a token instead."
  value       = local.client_key
  sensitive   = true
}

output "token" {
  description = "Bearer token from the kubeconfig, null when it authenticates with a client certificate instead."
  value       = local.token
  sensitive   = true
}
