# -----------------------------------------------------------------------------
# The hub: the principal, installed beside the Argo CD that the AKS Argo CD
# extension manages.
#
# The extension owns Argo CD itself — its deployments, its ConfigMaps, its
# upgrade path — and this stack deliberately does not touch any of that. What
# it adds is the piece the extension has no notion of: a gRPC endpoint that
# agents on other clouds dial into, and the Argo CD cluster registrations that
# make those agents show up as clusters in the existing UI.
#
# The argocd namespace is assumed to exist, because the extension created it.
# -----------------------------------------------------------------------------

# --- PKI, as the principal expects to find it -------------------------------
resource "kubernetes_secret_v1" "ca" {
  provider = kubernetes.azure

  metadata {
    name      = "argocd-agent-ca"
    namespace = local.hub_ns
    labels    = local.hub_labels
  }

  # The hub holds the key as well as the certificate: this is the only place
  # anything is ever signed. Spokes get the certificate alone.
  data = {
    "tls.crt" = tls_self_signed_cert.ca.cert_pem
    "tls.key" = tls_private_key.ca.private_key_pem
  }

  type = "kubernetes.io/tls"
}

resource "kubernetes_secret_v1" "principal_tls" {
  provider = kubernetes.azure

  metadata {
    name      = "argocd-agent-principal-tls"
    namespace = local.hub_ns
    labels    = local.hub_labels
  }

  data = {
    "tls.crt" = tls_locally_signed_cert.principal.cert_pem
    "tls.key" = tls_private_key.principal.private_key_pem
  }

  type = "kubernetes.io/tls"
}

resource "kubernetes_secret_v1" "resource_proxy_tls" {
  provider = kubernetes.azure

  metadata {
    name      = "argocd-agent-resource-proxy-tls"
    namespace = local.hub_ns
    labels    = local.hub_labels
  }

  data = {
    "tls.crt" = tls_locally_signed_cert.resource_proxy.cert_pem
    "tls.key" = tls_private_key.resource_proxy.private_key_pem
  }

  type = "kubernetes.io/tls"
}

resource "kubernetes_secret_v1" "redis_proxy_tls" {
  provider = kubernetes.azure

  metadata {
    name      = "argocd-redis-proxy-tls"
    namespace = local.hub_ns
    labels    = local.hub_labels
  }

  data = {
    "tls.crt" = tls_locally_signed_cert.redis_proxy.cert_pem
    "tls.key" = tls_private_key.redis_proxy.private_key_pem
  }

  type = "kubernetes.io/tls"
}

resource "kubernetes_secret_v1" "jwt" {
  provider = kubernetes.azure

  metadata {
    name      = "argocd-agent-jwt"
    namespace = local.hub_ns
    labels    = local.hub_labels
  }

  data = {
    "jwt.key" = tls_private_key.jwt.private_key_pem_pkcs8
  }

  type = "Opaque"
}

# --- The principal -----------------------------------------------------------
resource "helm_release" "principal" {
  provider = helm.azure

  name       = "argocd-agent-principal"
  repository = "oci://ghcr.io/argoproj-labs/argocd-agent"
  chart      = "argocd-agent-principal"
  version    = var.principal_chart_version
  namespace  = local.hub_ns

  values = [yamlencode({
    # Pinned so the Service names are predictable — they are baked into the
    # principal's server certificate and into the agents' configuration.
    fullnameOverride = "argocd-agent-principal"

    image = {
      repository = var.agent_image_repository
      tag        = var.agent_image_tag
    }

    # The one public surface in the whole topology. Everything else — the
    # resource proxy, the redis proxy, all three spokes — is either
    # cluster-internal or outbound-only.
    service = {
      type       = "LoadBalancer"
      port       = var.principal_port
      targetPort = 8443
      annotations = merge(
        { "service.beta.kubernetes.io/azure-dns-label-name" = local.principal_dns_label },
        var.principal_service_annotations,
      )
    }

    redisSecretName  = var.hub_redis_secret_name
    redisPasswordKey = "auth"

    principal = {
      namespace = local.hub_ns

      listen = {
        # Empty means all interfaces. Safe here precisely because
        # authentication is mTLS: with header-based auth this would have to
        # stay on loopback behind a proxy that sets the header.
        host = ""
        port = 8443
      }

      log = {
        level = var.hub_log_level
      }

      # The agent's name is read out of the client certificate's subject and
      # is then required to match a registered agent. Identity and credential
      # are the same object.
      auth = "mtls:CN=([^,]+)"

      tls = {
        secretName = kubernetes_secret_v1.principal_tls.metadata[0].name
        server = {
          rootCaSecretName = kubernetes_secret_v1.ca.metadata[0].name
        }
        clientCert = {
          require      = true
          matchSubject = true
        }
        minVersion = "tls1.3"
      }

      jwt = {
        secretName    = kubernetes_secret_v1.jwt.metadata[0].name
        allowGenerate = false
      }

      resourceProxy = {
        enabled    = true
        secretName = kubernetes_secret_v1.resource_proxy_tls.metadata[0].name
        ca = {
          secretName = kubernetes_secret_v1.ca.metadata[0].name
        }
      }

      redisProxy = {
        enabled = true
      }

      redis = {
        server = {
          address = var.hub_redis_address
        }
        proxy = {
          server = {
            tls = {
              secretName = kubernetes_secret_v1.redis_proxy_tls.metadata[0].name
            }
          }
        }
      }

      destinationBasedMapping = var.destination_based_mapping
    }

    rbac = {
      create            = true
      createClusterRole = true
    }
  })]

  depends_on = [
    kubernetes_secret_v1.ca,
    kubernetes_secret_v1.principal_tls,
    kubernetes_secret_v1.resource_proxy_tls,
    kubernetes_secret_v1.redis_proxy_tls,
    kubernetes_secret_v1.jwt,
  ]
}

# --- Agent registration ------------------------------------------------------
# An agent is "known" to the hub because an Argo CD cluster secret names it.
# The server it points at is the resource proxy, in-cluster, so the hub's
# Argo CD believes it is talking to a Kubernetes API server and never learns
# that the real one is on another cloud behind an outbound connection. The
# client certificate in the secret is the same agent identity the principal
# authenticates, which is how the proxy knows which connection to forward a
# request down.
resource "kubernetes_secret_v1" "cluster" {
  provider = kubernetes.azure
  for_each = local.agents

  metadata {
    name      = "cluster-${each.value.name}"
    namespace = local.hub_ns

    labels = merge(local.hub_labels, {
      "argocd.argoproj.io/secret-type"           = "cluster"
      "argocd-agent.argoproj-labs.io/agent-name" = each.value.name
    })

    annotations = {
      "managed-by" = "argocd-agent"
      # The hub runs an application controller of its own (the extension
      # installs the full Argo CD). This tells it to keep its hands off the
      # agents' clusters — those applications are the principal's to
      # reconcile, through the agent. Argo CD 3.4+.
      "argocd.argoproj.io/skip-reconcile" = "true"
    }
  }

  data = {
    name   = each.value.name
    server = "https://argocd-agent-resource-proxy:9090?agentName=${each.value.name}"

    config = jsonencode({
      tlsClientConfig = {
        insecure = false
        certData = base64encode(tls_locally_signed_cert.agent[each.key].cert_pem)
        keyData  = base64encode(tls_private_key.agent[each.key].private_key_pem)
        caData   = base64encode(tls_self_signed_cert.ca.cert_pem)
      }
    })
  }

  type = "Opaque"

  depends_on = [helm_release.principal]
}

# --- AKS Argo CD extension ---------------------------------------------------
# Off unless var.manage_hub_extension says otherwise; see the variable's
# description for why, and for the import that turning it on requires.
#
# The one setting this stack has an opinion about is redis.server: the hub's
# argocd-server has to read live application state through the principal's
# redis proxy, or the UI shows spoke applications as synced but cannot draw
# their resource trees. Everything else in configuration_settings is yours.
resource "azurerm_kubernetes_cluster_extension" "argocd" {
  count = var.manage_hub_extension ? 1 : 0

  name           = var.hub_extension_name
  cluster_id     = try(local.foundation.azure.cluster_id, null)
  extension_type = "Microsoft.ArgoCD"

  configuration_settings = merge(var.hub_extension_settings, local.hub_extension_required_settings)
}
