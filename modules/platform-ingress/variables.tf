variable "chart_version" {
  description = "Traefik Helm chart version."
  type        = string
  default     = "41.2.0"
}

variable "namespace" {
  description = "Namespace the ingress controller runs in. Tenant NetworkPolicies allow ingress from this namespace by its kubernetes.io/metadata.name label, so it must match the tenant module's ingress_controller_namespace."
  type        = string
  default     = "traefik"
}

variable "ingress_class_name" {
  description = "Name of the IngressClass Traefik creates. It is marked as the cluster default, so tenant Ingresses may omit ingressClassName."
  type        = string
  default     = "traefik"
}

variable "default_certificate_secret_name" {
  description = "Kubernetes TLS secret in var.namespace that Traefik's default TLSStore serves when a router matches no other certificate. The platform wildcard is materialized into it by var.extra_objects."
  type        = string
  default     = "platform-wildcard-tls"
}

variable "service_annotations" {
  description = "Annotations on the Traefik Service, used to select the cloud's load balancer type and sizing."
  type        = map(string)
  default     = {}
}

variable "extra_objects" {
  description = "Extra manifests rendered with the release, as a list of objects. This is where the cloud-specific certificate plumbing lives (ESO SecretStore + ExternalSecret, or a Secrets Store CSI SecretProviderClass)."
  type        = any
  default     = []
}

variable "additional_volumes" {
  description = "Extra pod volumes for the Traefik Deployment (Azure mounts the Key Vault certificate through the Secrets Store CSI driver here)."
  type        = any
  default     = []
}

variable "additional_volume_mounts" {
  description = "Extra volume mounts for the Traefik container, paired with var.additional_volumes."
  type        = any
  default     = []
}

variable "replicas" {
  description = "Number of Traefik replicas. One is enough for a prototype; raise it once the cluster has nodes to spread over."
  type        = number
  default     = 1
}

variable "resources" {
  description = "Resource requests/limits of the Traefik container."
  type        = any
  default = {
    requests = {
      cpu    = "100m"
      memory = "128Mi"
    }
    limits = {
      memory = "256Mi"
    }
  }
}

variable "extra_values" {
  description = "Extra Helm values merged over the ones this module builds (top-level keys win outright — the merge is not deep)."
  type        = any
  default     = {}
}

variable "wait" {
  description = "Block the apply until the release is ready. Turn it off where a Traefik pod can be held back by something outside this stack — on Azure the certificate is a CSI volume, so a vault without one would keep the pod from starting at all."
  type        = bool
  default     = true
}

variable "timeout" {
  description = "Seconds Helm waits for the release to become ready, including the cloud assigning the load balancer an address."
  type        = number
  default     = 900
}
