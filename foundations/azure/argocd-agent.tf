# argocd-agent's PRINCIPAL, the hub half of the pull-based delivery plane
# (https://github.com/argoproj-labs/argocd-agent).
#
# What this changes about the topology is one arrow. Argo CD used to reach each
# spoke by calling its Kubernetes API with a cluster-admin bearer token it held
# for that cluster, which meant every spoke had to publish a public API server
# and the hub had to hold four cluster-admin credentials. With the principal,
# each spoke runs an agent that dials *this* endpoint and keeps one gRPC stream
# open; nothing here ever contacts a spoke.
#
#   argocd-agent.onek8s.lol:8443           ┌──────── AKS (foundations/azure) ───────┐
#    (A record, out of band)               │                                        │
#            ▲                             │  Traefik ──TCP, TLS passthrough──▶     │
#            │                             │      argocd-agent-principal:443        │
#      agent on EKS ──────outbound─────────┼──────────────┘        │                │
#      agent on GKE ──────outbound─────────┤                       │ Applications,  │
#      agent on OKE ──────outbound─────────┘                       │ AppProjects    │
#                                          │                       ▼                │
#                                          │   Argo CD extension (argocd namespace) │
#                                          └────────────────────────────────────────┘
#
# TLS is NOT terminated at the ingress here, unlike every other host this
# platform publishes. The principal authenticates each agent by the common name
# of its client certificate, so the connection has to arrive with that
# certificate intact — hence an IngressRouteTCP with passthrough rather than an
# Ingress. Traefik matches on SNI and forwards bytes.
#
# HYBRID, not replacement. This cluster keeps its full Argo CD, because it is
# also a deployment target: the hello application's staging stage and db-hello
# both run here, reconciled by this cluster's own application-controller. The
# principal and the agents therefore filter on a label
# (local.argocd_agent_label_selector) and each spoke's cluster Secret carries
# argocd.argoproj.io/skip-reconcile, so the two controllers cannot end up
# reconciling the same Application. That is argocd-agent's documented hybrid
# arrangement, and it is the only one available to us anyway: the Argo CD here
# is an Azure-managed extension whose application-controller we could not
# remove if we wanted to.
locals {
  # The principal shares the extension's namespace: it reads the Applications
  # and AppProjects Argo CD holds, writes the status back into them, and its
  # redis proxy sits in front of the extension's own redis. Nothing about that
  # works across a namespace boundary.
  argocd_agent_namespace = local.argocd_namespace

  argocd_agent_release = "argocd-agent-principal"

  # Chart helper: release name == chart name, so every object is named for the
  # release, and the gRPC Service is "argocd-agent-principal".
  argocd_agent_service_name = local.argocd_agent_release

  # The port the principal's Service answers on inside the cluster. The agents
  # never see it — they dial var.argocd_agent_port on the ingress.
  argocd_agent_service_port = 443

  # Fixed by the chart, and named in the cluster Secret every spoke gets: Argo
  # CD asks this address for the live resources of an agent's Applications, and
  # the principal forwards the question down the agent's own connection.
  argocd_agent_resource_proxy_service = "argocd-agent-resource-proxy"
  argocd_agent_resource_proxy_port    = 9090
  argocd_agent_resource_proxy_address = "${local.argocd_agent_resource_proxy_service}:${local.argocd_agent_resource_proxy_port}"

  # The redis proxy, and the reason argocd.tf points argocd-server at it. It
  # routes the two key prefixes that belong to an agent's Applications
  # ("app|resources-tree|…", "app|managed-resources|…") down the agent
  # connection and everything else to the extension's redis, which is what
  # makes the UI able to draw an agent-managed Application's resource tree at
  # all. It is plaintext on 6379, exactly like the redis it fronts, because
  # principal.redis.tls.enabled is false.
  argocd_agent_redis_proxy_address = "argocd-agent-redis-proxy:6379"

  # The hybrid boundary. Principal and agent only look at Applications,
  # AppProjects and repository Secrets carrying this label; everything without
  # it stays the business of this cluster's own application-controller. The
  # delivery-plane chart puts it on the objects that belong to a spoke.
  argocd_agent_label_selector = "${var.argocd_agent_label}=true"

  # Enabled only where there is an Argo CD to be the principal of, and an
  # ingress to publish it through: the connection is a TCP entrypoint on the
  # Traefik load balancer, so an environment with enable_ingress = false has
  # nowhere to put it.
  argocd_agent_enabled = var.enable_argocd && var.enable_argocd_agent && var.enable_ingress

  argocd_agent_address = var.argocd_agent_hostname
}

# --- PKI ---------------------------------------------------------------------
# `argocd-agentctl pki init` is documented as NON-PROD, and it is a one-shot
# imperative command besides — the CA it writes exists only on the cluster, so
# an extension reinstall (which takes the release namespace with it) would lose
# it and every agent with it. Minting it here instead makes the whole PKI a
# function of this state: re-applying restores byte-identical Secrets and every
# agent reconnects.
#
# The trade is that the CA private key lives in this stack's state, and in the
# gitops state that reads it back to sign each agent's certificates. It is the
# most valuable thing either state file holds — it mints agent identities — but
# it is still strictly less than what it replaces, which was a cluster-admin
# bearer token for every spoke.
resource "tls_private_key" "argocd_agent_ca" {
  count = local.argocd_agent_enabled ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "argocd_agent_ca" {
  count = local.argocd_agent_enabled ? 1 : 0

  private_key_pem   = tls_private_key.argocd_agent_ca[0].private_key_pem
  is_ca_certificate = true

  subject {
    common_name  = "argocd-agent-ca"
    organization = "OneK8s ${var.environment}"
  }

  validity_period_hours = var.argocd_agent_ca_validity_hours
  early_renewal_hours   = var.argocd_agent_ca_early_renewal_hours

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]
}

# The CA Secret the principal reads to validate the client certificate an agent
# connects with, and the one the gitops stack reads back to sign those
# certificates. Both halves, as a kubernetes.io/tls Secret — the same shape
# `argocd-agentctl pki init` produces. Each spoke gets the certificate alone.
resource "kubernetes_secret_v1" "argocd_agent_ca" {
  count = local.argocd_agent_enabled ? 1 : 0

  metadata {
    name      = "argocd-agent-ca"
    namespace = local.argocd_agent_namespace
    labels    = local.argocd_agent_labels
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = tls_self_signed_cert.argocd_agent_ca[0].cert_pem
    "tls.key" = tls_private_key.argocd_agent_ca[0].private_key_pem
  }

  depends_on = [azurerm_kubernetes_cluster_extension.argocd]
}

# The certificate the principal serves on the gRPC listener. Its subject
# alternative names are what an agent validates, and because Traefik passes the
# connection through rather than terminating it, the name that matters is the
# public host — not the Service.
resource "tls_private_key" "argocd_agent_principal" {
  count = local.argocd_agent_enabled ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "argocd_agent_principal" {
  count = local.argocd_agent_enabled ? 1 : 0

  private_key_pem = tls_private_key.argocd_agent_principal[0].private_key_pem

  subject {
    common_name = local.argocd_agent_address
  }

  dns_names = concat([
    local.argocd_agent_address,
    local.argocd_agent_service_name,
    "${local.argocd_agent_service_name}.${local.argocd_agent_namespace}",
    "${local.argocd_agent_service_name}.${local.argocd_agent_namespace}.svc",
    "${local.argocd_agent_service_name}.${local.argocd_agent_namespace}.svc.cluster.local",
  ], var.argocd_agent_extra_dns_names)
}

resource "tls_locally_signed_cert" "argocd_agent_principal" {
  count = local.argocd_agent_enabled ? 1 : 0

  cert_request_pem   = tls_cert_request.argocd_agent_principal[0].cert_request_pem
  ca_private_key_pem = tls_private_key.argocd_agent_ca[0].private_key_pem
  ca_cert_pem        = tls_self_signed_cert.argocd_agent_ca[0].cert_pem

  validity_period_hours = var.argocd_agent_certificate_validity_hours
  early_renewal_hours   = var.argocd_agent_certificate_early_renewal_hours

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
  ]
}

resource "kubernetes_secret_v1" "argocd_agent_principal_tls" {
  count = local.argocd_agent_enabled ? 1 : 0

  metadata {
    name      = "argocd-agent-principal-tls"
    namespace = local.argocd_agent_namespace
    labels    = local.argocd_agent_labels
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = tls_locally_signed_cert.argocd_agent_principal[0].cert_pem
    "tls.key" = tls_private_key.argocd_agent_principal[0].private_key_pem
  }

  depends_on = [azurerm_kubernetes_cluster_extension.argocd]
}

# The resource proxy's certificate. This one is only ever presented to Argo CD
# inside this cluster, so the Service name is the whole of it — and it has to
# match the address in every spoke's cluster Secret exactly, or Argo CD refuses
# the connection and every agent-managed Application shows an empty tree.
resource "tls_private_key" "argocd_agent_resource_proxy" {
  count = local.argocd_agent_enabled ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "argocd_agent_resource_proxy" {
  count = local.argocd_agent_enabled ? 1 : 0

  private_key_pem = tls_private_key.argocd_agent_resource_proxy[0].private_key_pem

  subject {
    common_name = local.argocd_agent_resource_proxy_service
  }

  dns_names = [
    local.argocd_agent_resource_proxy_service,
    "${local.argocd_agent_resource_proxy_service}.${local.argocd_agent_namespace}",
    "${local.argocd_agent_resource_proxy_service}.${local.argocd_agent_namespace}.svc",
    "${local.argocd_agent_resource_proxy_service}.${local.argocd_agent_namespace}.svc.cluster.local",
  ]
}

resource "tls_locally_signed_cert" "argocd_agent_resource_proxy" {
  count = local.argocd_agent_enabled ? 1 : 0

  cert_request_pem   = tls_cert_request.argocd_agent_resource_proxy[0].cert_request_pem
  ca_private_key_pem = tls_private_key.argocd_agent_ca[0].private_key_pem
  ca_cert_pem        = tls_self_signed_cert.argocd_agent_ca[0].cert_pem

  validity_period_hours = var.argocd_agent_certificate_validity_hours
  early_renewal_hours   = var.argocd_agent_certificate_early_renewal_hours

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
  ]
}

resource "kubernetes_secret_v1" "argocd_agent_resource_proxy_tls" {
  count = local.argocd_agent_enabled ? 1 : 0

  metadata {
    name      = "argocd-agent-resource-proxy-tls"
    namespace = local.argocd_agent_namespace
    labels    = local.argocd_agent_labels
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = tls_locally_signed_cert.argocd_agent_resource_proxy[0].cert_pem
    "tls.key" = tls_private_key.argocd_agent_resource_proxy[0].private_key_pem
  }

  depends_on = [azurerm_kubernetes_cluster_extension.argocd]
}

# The key the principal signs its internal tokens with. The chart can generate
# one itself (principal.jwt.allowGenerate), which is off here for the same
# reason the CA is minted in Terraform: a key that only exists on the cluster
# is a key the extension's next reinstall silently rotates.
resource "tls_private_key" "argocd_agent_jwt" {
  count = local.argocd_agent_enabled ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "kubernetes_secret_v1" "argocd_agent_jwt" {
  count = local.argocd_agent_enabled ? 1 : 0

  metadata {
    name      = "argocd-agent-jwt"
    namespace = local.argocd_agent_namespace
    labels    = local.argocd_agent_labels
  }

  type = "Opaque"

  data = {
    "jwt.key" = tls_private_key.argocd_agent_jwt[0].private_key_pem
  }

  depends_on = [azurerm_kubernetes_cluster_extension.argocd]
}

# --- The principal -----------------------------------------------------------
locals {
  argocd_agent_labels = {
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/part-of"    = "onek8s"
    "onek8s.io/environment"        = var.environment
  }

  argocd_agent_values = merge({
    principal = {
      # 0.0.0.0, not the chart's 127.0.0.1 default: the listener has to accept
      # the connection Traefik forwards from another pod.
      listen = {
        host = "0.0.0.0"
        port = 8443
      }

      # The namespace whose Argo CD objects the principal manages. With
      # destination-based mapping the agent an Application belongs to is read
      # from its spec.destination.name rather than from its namespace, so one
      # namespace serves every agent — and, more to the point, the
      # ApplicationSets on this hub need no change at all: they already address
      # a cluster by the name Argo CD knows it by.
      namespace               = local.argocd_agent_namespace
      destinationBasedMapping = true

      # The hybrid boundary; see the header. Both ends filter on it.
      labelSelector = local.argocd_agent_label_selector

      # An agent is whoever its client certificate says it is. Requiring and
      # matching the certificate is what makes that a claim the principal can
      # rely on rather than a name in a header.
      auth = "mtls:CN=([^,]+)"

      tls = {
        secretName = "argocd-agent-principal-tls"
        server = {
          allowGenerate    = false
          rootCaSecretName = "argocd-agent-ca"
        }
        clientCert = {
          require      = true
          matchSubject = true
        }
        minVersion = "tls1.3"
      }

      resourceProxy = {
        enabled    = true
        secretName = "argocd-agent-resource-proxy-tls"
        ca         = { secretName = "argocd-agent-ca" }
      }

      jwt = {
        allowGenerate = false
        secretName    = "argocd-agent-jwt"
      }

      redisProxy = { enabled = true }
      redis = {
        server = { address = "${local.argocd_redis_service_name}:6379" }
        # Plaintext, matching the extension's own redis and the plaintext
        # client argocd-server is. Enabling it here would mean a certificate
        # for the proxy AND a redis client on the Argo CD side configured for
        # TLS, which the extension does not expose.
        tls = { enabled = false }
      }

      log = { level = var.argocd_agent_log_level }
    }

    # ClusterIP: the public address is the ingress load balancer's, and the
    # route in front of it is an IngressRouteTCP rendered with the Traefik
    # release (ingress.tf). A LoadBalancer here would be a second public IP and
    # a second A record for one platform.
    service = {
      type       = "ClusterIP"
      port       = local.argocd_agent_service_port
      targetPort = 8443
    }

    rbac = {
      create            = true
      createClusterRole = true
    }

    resources = var.argocd_agent_resources
  }, var.argocd_agent_extra_values)
}

resource "helm_release" "argocd_agent_principal" {
  count = local.argocd_agent_enabled ? 1 : 0

  name       = local.argocd_agent_release
  repository = var.argocd_agent_chart_repository
  chart      = "argocd-agent-principal"
  version    = var.argocd_agent_chart_version
  namespace  = local.argocd_agent_namespace

  # The namespace and the redis it fronts belong to the extension, and the
  # release is applied into it rather than creating it.
  create_namespace = false

  values = [yamlencode(local.argocd_agent_values)]

  depends_on = [
    azurerm_kubernetes_cluster_extension.argocd,
    kubernetes_secret_v1.argocd_agent_ca,
    kubernetes_secret_v1.argocd_agent_principal_tls,
    kubernetes_secret_v1.argocd_agent_resource_proxy_tls,
    kubernetes_secret_v1.argocd_agent_jwt,
  ]
}

# --- The agents' way in, on the ingress load balancer ------------------------
# Consumed by module "ingress" in ingress.tf, the same way Portainer's Edge
# tunnel is. Two pieces:
#
#   * an extra entrypoint, which opens var.argocd_agent_port on the ingress
#     Service and therefore on the Azure load balancer, and
#   * an IngressRouteTCP with TLS PASSTHROUGH, which is the part that differs
#     from every other host here. Traefik reads the SNI to pick the route and
#     then forwards the bytes untouched, so the principal receives the agent's
#     client certificate and can authenticate it. Terminating TLS at Traefik —
#     what an ordinary Ingress does — would strip exactly the thing the
#     principal authenticates with.
#
# The route carries its own namespace so Helm applies it into the Argo CD
# namespace, next to the Service it names, keeping the reference
# same-namespace: cross-namespace references would need allowCrossNamespace,
# which would also let any tenant's IngressRoute reach into any other
# namespace.
locals {
  argocd_agent_entrypoint = "argocd-agent"

  # What the entrypoint listens on inside the Traefik pod. It cannot be 8443:
  # the chart runs the websecure entrypoint on container port 8443, and two
  # entrypoints on one container port make Traefik refuse to start. Only the
  # exposed port has to be the one agents dial.
  argocd_agent_container_port = 8543

  argocd_agent_ingress_ports = local.argocd_agent_enabled ? {
    (local.argocd_agent_entrypoint) = {
      port        = local.argocd_agent_container_port
      exposedPort = var.argocd_agent_port
      expose      = { default = true }
      protocol    = "TCP"
    }
  } : {}

  argocd_agent_ingress_objects = local.argocd_agent_enabled ? [{
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRouteTCP"
    metadata = {
      name      = "argocd-agent"
      namespace = local.argocd_agent_namespace
    }
    spec = {
      entryPoints = [local.argocd_agent_entrypoint]
      # Passthrough, so the client certificate survives the hop. Traefik needs
      # no certificate of its own for this route and the platform wildcard is
      # not involved: the principal serves the certificate minted above.
      tls = { passthrough = true }
      routes = [{
        # Matched on SNI, which an agent sets to the host it dialled. Naming
        # the host rather than "*" leaves the entrypoint free for a second
        # route later, and makes a connection to the wrong name fail here
        # rather than at the principal's certificate check.
        match = "HostSNI(`${local.argocd_agent_address}`)"
        services = [{
          name = local.argocd_agent_service_name
          port = local.argocd_agent_service_port
        }]
      }]
    }
  }] : []
}
