variable "environment" {
  description = "Environment name (prototype, dev, staging, prod). Used in resource names, the Vault mount path and secret prefixes."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for all resource names, e.g. 'onek8s'."
  type        = string
  default     = "onek8s"
}

# --- NKP management cluster ---------------------------------------------------
# The private cloud's control plane. Everything about the workload cluster —
# creating it, and reading back the credentials to reach it — goes through this
# API, which is why there are no Prism Central credentials in this stack: NKP
# holds them, in the Secret its own cluster manifests reference.
variable "nkp_management_host" {
  description = "API server URL of the NKP management cluster, e.g. 'https://nkp.example.internal:6443'."
  type        = string
}

variable "nkp_management_ca_certificate" {
  description = "Base64-encoded CA certificate of the NKP management cluster's API server. Empty falls back to the runner's trust store, which is what a publicly-trusted certificate needs."
  type        = string
  default     = ""
}

variable "nkp_management_token" {
  description = "Bearer token of a ServiceAccount on the NKP management cluster with rights over this cluster's workspace namespace. Supply it through the environment (TF_VAR_nkp_management_token), never in a tfvars file."
  type        = string
  sensitive   = true
}

# --- The workload cluster -----------------------------------------------------
variable "cluster_name" {
  description = "Name of the NKP workload cluster this foundation builds the platform on. Null defaults to '<name_prefix>-<environment>'."
  type        = string
  default     = null
}

variable "cluster_namespace" {
  description = "Namespace on the management cluster holding the cluster object and its kubeconfig Secret. NKP puts a workspace's clusters in that workspace's namespace."
  type        = string
  default     = "kommander-default-workspace"
}

variable "cluster_manifests_dir" {
  description = <<-EOT
    Directory of Cluster API manifests that create the workload cluster,
    applied to the NKP management cluster. Generate them with the NKP CLI
    rather than writing them by hand:

      nkp create cluster nutanix --cluster-name <name> ... --dry-run -o yaml \
        > foundations/nutanix/cluster/<env>.yaml

    Empty (the default) creates nothing and attaches to a cluster NKP already
    manages — which is what a cluster created from the NKP UI or CLI wants.
    Either way the credentials come from the same place: the Cluster API
    kubeconfig Secret on the management cluster.
  EOT
  type        = string
  default     = ""
}

# --- HashiCorp Vault ----------------------------------------------------------
# The secret backend. Vault itself is a prerequisite, the way a Nutanix cluster
# and Prism Central are: this stack creates the environment's KV v2 mount and
# its Kubernetes auth mount inside an existing Vault, which is the private
# cloud's equivalent of creating a Key Vault in a subscription that exists.
variable "vault_address" {
  description = "Address of the Vault server, e.g. 'https://vault.example.internal:8200'. The Terraform run and, at runtime, External Secrets in the cluster both have to reach it."
  type        = string
}

variable "vault_namespace" {
  description = "Vault namespace everything is created in (Vault Enterprise / HCP Vault Dedicated). Empty uses the root namespace, which is what Vault Community has."
  type        = string
  default     = ""
}

variable "vault_ca_bundle" {
  description = "Base64-encoded PEM CA bundle for Vault's own TLS certificate, passed to the in-cluster SecretStores. Empty relies on the cluster's trust store, which is what a publicly-trusted certificate needs."
  type        = string
  default     = ""
}

variable "vault_mount_path" {
  description = "Path of the KV v2 mount holding this environment's secrets — the 'vault' half of the foundation pair. Null defaults to '<name_prefix>-<environment>'."
  type        = string
  default     = null
}

variable "vault_auth_path" {
  description = "Path of the Kubernetes auth mount that trusts this cluster. One mount per cluster, so a role name means one thing. Null defaults to 'kubernetes-<name_prefix>-<environment>'."
  type        = string
  default     = null
}

variable "vault_token_ttl" {
  description = "TTL, in seconds, of the Vault tokens issued to workloads of this cluster. Short by design: External Secrets logs in again on every refresh."
  type        = number
  default     = 3600
}

# --- Cluster add-ons ----------------------------------------------------------
variable "eso_chart_version" {
  description = "External Secrets Operator Helm chart version."
  type        = string
  default     = "2.9.0"
}

variable "enable_ingress" {
  description = "Install Traefik as the cluster's ingress controller, with the distributed platform wildcard as its default certificate."
  type        = bool
  default     = true
}

variable "traefik_chart_version" {
  description = "Traefik Helm chart version."
  type        = string
  default     = "41.2.0"
}

variable "ingress_certificate_name" {
  description = "Vault secret holding the platform wildcard certificate, as the Renew Certificate workflow's distribute mode writes it. Reserved 'platform-' prefix: no tenant identity can read it."
  type        = string
  default     = "platform-wildcard-onek8s-lol"
}

variable "ingress_load_balancer_ip" {
  description = "Address to request for the ingress Service. A private cloud has no cloud load balancer behind type=LoadBalancer, so this is an address out of the pool of whatever provides them (MetalLB on NKP). Null takes the next free one."
  type        = string
  default     = null
}

variable "ingress_service_annotations" {
  description = "Extra annotations for the Traefik Service, e.g. to select a MetalLB address pool."
  type        = map(string)
  default     = {}
}

variable "ingress_dashboard_hostname" {
  description = "Host the Traefik dashboard and API are published on. Served UNAUTHENTICATED — anyone who reaches it reads the cluster's whole routing configuration — so it is a lab convenience; set it to null to keep the dashboard reachable only through kubectl port-forward. Must be one label deep under the wildcard, and needs a DNS record pointed at the ingress address."
  type        = string
  default     = "nutanix-traefik.onek8s.lol"
}

variable "labels" {
  description = "Extra labels applied to the Kubernetes objects this stack owns."
  type        = map(string)
  default     = {}
}
