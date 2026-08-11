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

output "environment" {
  description = "Environment this foundation was deployed for."
  value       = var.environment
}
