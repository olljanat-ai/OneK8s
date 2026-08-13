output "cluster_id" {
  description = "OKE cluster OCID. Pins tenant workload-identity policies to this cluster."
  value       = oci_containerengine_cluster.this.id
}

output "cluster_name" {
  description = "OKE cluster name."
  value       = oci_containerengine_cluster.this.name
}

output "cluster_endpoint" {
  description = "OKE API server endpoint (https URL)."
  value       = local.kube_host
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate."
  value       = local.kube_config["clusters"][0]["cluster"]["certificate-authority-data"]
}

output "vault_id" {
  description = "OCID of the OCI Vault holding all tenant secrets."
  value       = oci_kms_vault.secrets.id
}

output "vault_key_id" {
  description = "OCID of the master encryption key protecting tenant secrets."
  value       = oci_kms_key.secrets.id
}

output "compartment_id" {
  description = "OCID of the compartment holding the cluster and the vault."
  value       = var.compartment_ocid
}

output "tenancy_id" {
  description = "OCID of the tenancy."
  value       = var.tenancy_ocid
}

output "region" {
  description = "OCI region of the cluster and secret backend."
  value       = var.region
}

output "home_region" {
  description = "Tenancy home region, where IAM policies must be written."
  value       = coalesce(var.home_region, var.region)
}

output "environment" {
  description = "Environment this foundation was deployed for."
  value       = var.environment
}
