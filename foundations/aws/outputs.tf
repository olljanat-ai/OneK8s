output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "oidc_issuer_url" {
  description = "Cluster OIDC issuer URL (IRSA)."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for IRSA trust policies."
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "secrets_kms_key_arn" {
  description = "ARN of the CMK encrypting tenant secrets in Secrets Manager."
  value       = aws_kms_key.secrets.arn
}

output "region" {
  description = "AWS region of the cluster and secret backend."
  value       = var.region
}

output "account_id" {
  description = "AWS account ID."
  value       = data.aws_caller_identity.current.account_id
}

output "ingress_class_name" {
  description = "IngressClass of the Traefik ingress controller (the cluster default), null when ingress is disabled."
  value       = var.enable_ingress ? local.ingress_class_name : null
}

output "ingress_namespace" {
  description = "Namespace the ingress controller runs in; tenant NetworkPolicies allow ingress from it."
  value       = var.enable_ingress ? local.ingress_namespace : null
}

output "ingress_default_certificate_secret" {
  description = "TLS secret in the ingress namespace that Traefik serves for hosts without a certificate of their own — the platform wildcard, read from Secrets Manager by External Secrets."
  value       = var.enable_ingress ? local.ingress_tls_secret_name : null
}

output "ingress_dashboard_url" {
  description = "URL of the Traefik dashboard, null when ingress or the dashboard is disabled."
  value       = var.enable_ingress ? module.ingress[0].dashboard_url : null
}

output "environment" {
  description = "Environment this foundation was deployed for."
  value       = var.environment
}
