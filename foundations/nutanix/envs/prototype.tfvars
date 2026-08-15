environment = "prototype"
name_prefix = "onek8s"

# The NKP management cluster. Its bearer token is deliberately not here: pass
# it as TF_VAR_nkp_management_token, the same way the OCI signing key and the
# AWS keys come from the environment.
nkp_management_host = "https://nkp.onek8s.internal:6443"
# Base64 of the management cluster's CA certificate. Empty relies on the
# runner's trust store.
nkp_management_ca_certificate = ""

# The workload cluster NKP manages for this environment. It is created with
# `nkp create cluster nutanix` (see docs/nutanix.md) and attached to here;
# cluster_manifests_dir is what makes this stack create it instead.
cluster_name      = "onek8s-prototype"
cluster_namespace = "kommander-default-workspace"

# HashiCorp Vault: the private cloud's secret backend. VAULT_TOKEN comes from
# the environment. The KV v2 mount and the Kubernetes auth mount are created by
# this stack and default to "onek8s-prototype" / "kubernetes-onek8s-prototype".
vault_address = "https://vault.onek8s.internal:8200"
# Base64 of the PEM CA bundle for Vault's own certificate — a private CA is the
# normal case on a private cloud, and both this stack and every in-cluster
# SecretStore need to trust it.
vault_ca_bundle = ""

# A private cloud has no cloud load balancer: MetalLB hands out the address, so
# pin the one the DNS records point at.
ingress_load_balancer_ip = null
