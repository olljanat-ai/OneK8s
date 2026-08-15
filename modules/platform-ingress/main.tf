# Traefik as the platform ingress controller, installed identically on every
# cloud. Everything that differs between clouds is an input: the Service
# annotations that pick the cloud's load balancer, and the objects that
# materialize the platform wildcard certificate into
# var.default_certificate_secret_name — an ESO SecretStore + ExternalSecret on
# every cloud, differing only in the provider block and the identity it
# authenticates as.
#
# The point of the default certificate is that a tenant Ingress carries no TLS
# configuration at all: Traefik's default TLSStore hands every websecure
# router the wildcard, so an Ingress only has to name a host under the
# certificate's domain.
locals {
  # A one-or-zero element list rather than a bool, so everything below is a
  # comprehension: the objects that mention the host are only built when there
  # is a host to mention.
  dashboard_hosts   = var.dashboard_hostname == null ? [] : [var.dashboard_hostname]
  dashboard_enabled = length(local.dashboard_hosts) > 0

  # api@internal answers on /api and /dashboard/, so a request to the bare
  # host would 404. One redirect makes the published URL the one an operator
  # actually types.
  dashboard_redirect_name = "dashboard-root-redirect"

  dashboard_objects = [for host in local.dashboard_hosts : {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name = local.dashboard_redirect_name
    }
    spec = {
      redirectRegex = {
        regex       = "^https?://[^/]+/?$"
        replacement = "https://${host}/dashboard/"
      }
    }
  }]

  dashboard_values = merge({ enabled = local.dashboard_enabled }, [
    for host in local.dashboard_hosts : {
      # websecure only: the default "traefik" entrypoint is not exposed by the
      # Service, and :80 permanently redirects here anyway.
      entryPoints = ["websecure"]
      # The whole host, so /api answers next to /dashboard/. TLS is the
      # entrypoint's, so this route is served the platform wildcard like
      # everything else.
      matchRule   = "Host(`${host}`)"
      middlewares = [{ name = local.dashboard_redirect_name }]
    }
  ]...)

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

    # The dashboard and the API, published on var.dashboard_hostname when one
    # is given. There is no authentication in front of either: whoever reaches
    # the host reads the cluster's whole routing configuration — every router,
    # service, middleware and which certificates are loaded. Leave the
    # hostname null anywhere that is not a lab.
    ingressRoute = {
      dashboard = local.dashboard_values
    }

    providers = {
      kubernetesIngress = {
        # Traefik writes its own Service's address into the status of every
        # Ingress it serves, so `kubectl get ingress` shows where to point the
        # host's DNS record — which is a manual step on every cloud here — and
        # an Ingress becomes usable as a source if external-dns is ever added.
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

    # "spec" is merged in rather than always set, so a cloud that does not use
    # it renders exactly the values it rendered before this existed.
    service = merge(
      { annotations = var.service_annotations },
      length(var.service_spec) > 0 ? { spec = var.service_spec } : {},
    )

    resources = var.resources

    extraObjects = concat(local.dashboard_objects, var.extra_objects)
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
  timeout = var.timeout
}
