# Traefik as the platform ingress controller, installed identically on every
# cloud. Everything that differs between clouds is an input: the Service
# annotations that pick the cloud's load balancer, and the objects that
# materialize the platform wildcard certificate into
# var.default_certificate_secret_name (an ESO SecretStore + ExternalSecret on
# AWS/GCP/OCI, a Secrets Store CSI SecretProviderClass on Azure).
#
# The point of the default certificate is that a tenant Ingress carries no TLS
# configuration at all: Traefik's default TLSStore hands every websecure
# router the wildcard, so an Ingress only has to name a host under the
# certificate's domain.
locals {
  # Rendered as the chart's `extraObjects`, which runs each entry through
  # Go templating; nothing here contains template syntax, so the manifests
  # pass through unchanged.
  values = merge({
    # One IngressClass, and it is the cluster default, so a tenant Ingress
    # needs neither ingressClassName nor an annotation.
    ingressClass = {
      enabled        = true
      isDefaultClass = true
      name           = var.ingress_class_name
    }

    deployment = {
      replicas          = var.replicas
      additionalVolumes = var.additional_volumes
    }
    additionalVolumeMounts = var.additional_volume_mounts

    # The dashboard is an IngressRoute on the same public load balancer with
    # no authentication in front of it; keep it to `kubectl port-forward`.
    ingressRoute = {
      dashboard = {
        enabled = false
      }
    }

    providers = {
      kubernetesIngress = {
        # Traefik writes its own Service's address into the status of every
        # Ingress it serves. That is what makes an Ingress usable as an
        # external-dns source, and it is how an operator finds the address to
        # point a record at.
        publishedService = {
          enabled = true
        }
      }
    }

    ports = {
      web = {
        http = {
          redirections = {
            entryPoint = {
              to        = "websecure"
              scheme    = "https"
              permanent = true
            }
          }
        }
      }
      websecure = {
        http = {
          tls = {
            enabled = true
          }
        }
      }
    }

    # The default certificate. A router that matches no other certificate —
    # which is every tenant Ingress, since none of them carry one — is served
    # this one.
    tlsStore = {
      default = {
        defaultCertificate = {
          secretName = var.default_certificate_secret_name
        }
      }
    }

    service = {
      annotations = var.service_annotations
    }

    resources = var.resources

    extraObjects = var.extra_objects
  }, var.extra_values)
}

resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true

  values = [yamlencode(local.values)]

  # A LoadBalancer Service is only ready once the cloud has handed it an
  # address, which takes minutes on some clouds — more than the provider's
  # 5-minute default.
  wait    = var.wait
  timeout = var.timeout
}
