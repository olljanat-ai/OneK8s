output "namespace" {
  description = "Namespace the ingress controller runs in."
  value       = var.namespace
}

output "ingress_class_name" {
  description = "IngressClass tenant and platform Ingresses are served by (the cluster default)."
  value       = var.ingress_class_name
}

output "default_certificate_secret_name" {
  description = "TLS secret Traefik serves for any router that carries no certificate of its own."
  value       = var.default_certificate_secret_name
}

output "release_name" {
  description = "Name of the Traefik Helm release."
  value       = helm_release.traefik.name
}
