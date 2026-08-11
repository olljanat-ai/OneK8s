# Unified, cloud-agnostic entry point of the tenant-namespace module.
# Provider requirements live in the cloud-specific submodules; the root
# configuration must configure all of them (see tenants/providers.tf).
terraform {
  required_version = ">= 1.9.0"
}
