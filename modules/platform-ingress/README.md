# platform-ingress module

Installs **Traefik** as the platform ingress controller on one cluster. It is
the same module on all four clouds — AKS, EKS, GKE and OKE — so a tenant sees
the same Ingress behaviour wherever its namespace happens to live.

```hcl
module "ingress" {
  source = "../../modules/platform-ingress"
  count  = var.enable_ingress ? 1 : 0

  chart_version       = var.traefik_chart_version
  service_annotations = { "service.beta.kubernetes.io/aws-load-balancer-type" = "nlb" }
  extra_objects       = [/* ServiceAccount + SecretStore + ExternalSecret */]
}
```

## What it configures

| Concern | Setting |
|---|---|
| IngressClass | `traefik`, marked as the **cluster default**, so a tenant Ingress needs no `ingressClassName` |
| HTTP | `web` (:80) permanently redirects to `websecure` (:443) |
| TLS | `websecure` terminates TLS; the default `TLSStore` serves `platform-wildcard-tls` |
| Address | `Service` type `LoadBalancer`, annotated per cloud; Traefik publishes it into every Ingress' status |
| Dashboard + API | published on `var.dashboard_hostname` when one is given, **unauthenticated**; null keeps it off |
| Extra entrypoints | `var.extra_ports`, merged into the chart's `ports` — see below |

## The dashboard and API

Setting `dashboard_hostname` publishes Traefik's own `api@internal` on that
host over `websecure`: the UI at `/dashboard/`, the read-only API at `/api`,
and a redirect so the bare host lands on the UI. The route matches the whole
host, is served the platform wildcard like everything else, and has **no
authentication in front of it** — whoever can reach the host reads every
router, service, middleware and loaded certificate on that cluster. It is a
lab convenience; leave the variable null anywhere else, and reach the
dashboard with:

```bash
kubectl -n traefik port-forward deploy/traefik 8080:8080   # http://localhost:8080/dashboard/
```

## The default certificate

The module does **not** fetch the certificate; it only points Traefik's
default `TLSStore` at `var.default_certificate_secret_name`. Filling that
secret is the caller's job and is the one genuinely cloud-shaped part, so it
is passed in as `extra_objects`: a platform `ServiceAccount`, a namespaced ESO
`SecretStore` bound to it, and an `ExternalSecret` writing a
`kubernetes.io/tls` secret. Only the provider block and the identity differ:

| Cloud | `SecretStore` provider | Identity | Shape in the backend |
|---|---|---|---|
| Azure | `azurekv` | UAMI + federated credential | one PEM bundle, split with `filterPEM` |
| AWS | `aws` (SecretsManager) | IAM role via IRSA | `{"tls.crt", "tls.key"}`, `dataFrom.extract` |
| GCP | `gcpsm` | GSA + Workload Identity | same |
| OCI | `oracle` | OKE Workload Identity | same |

All four converge on one Kubernetes TLS secret, which is why the Traefik
configuration above is identical everywhere.

Because the certificate is served as the default, **a tenant Ingress carries
no `tls:` block and references no secret**:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  namespace: team-alpha
spec:
  rules:
    - host: web-team-alpha.onek8s.lol   # covered by *.onek8s.lol
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 80
```

The hostname must be **one label deep** under the certificate's domain:
`*.onek8s.lol` covers `web-team-alpha.onek8s.lol` but not
`web.team-alpha.onek8s.lol`.

## Extra entrypoints

`extra_ports` is merged into the chart's `ports` map, so a caller can open a
port on the ingress load balancer for something that does not speak HTTP —
the Azure foundation uses it for Portainer's Edge tunnel:

```hcl
extra_ports = {
  portainer-edge = {
    port        = 8100          # inside the pod: must not collide with web (8000),
    exposedPort = 8000          # websecure (8443), traefik (8080) or metrics (9100)
    expose      = { default = true }
    protocol    = "TCP"
  }
}
```

Two entrypoints on one container port make Traefik refuse to start, which is
why the internal and the exposed port are separate here. Everything listed
becomes public on the load balancer, so nothing belongs here that is not meant
to be. Routing the traffic on is the caller's job, usually an `IngressRouteTCP`
passed through `extra_objects`.

## Notes

- `extra_objects` is rendered through the chart's `extraObjects`, which passes
  each manifest through Go templating. Nothing here uses template syntax, but
  a caller that adds `{{ … }}` should expect it to be evaluated.
- ESO objects in `extra_objects` need the External Secrets CRDs to exist when
  the release is applied. Callers order that with `depends_on` on the ESO
  release rather than by using `kubernetes_manifest`, which would need the
  CRDs at *plan* time — before the foundation has ever been applied.
- A vault that has no certificate yet leaves the `ExternalSecret` unresolved
  and Traefik serving its own self-signed certificate. The apply still
  succeeds, so a new environment can be built before the certificate exists
  and picks it up on its own afterwards.
- Reaching a tenant workload also needs the tenant's NetworkPolicy to allow
  this namespace; `modules/tenant-namespace` does that by matching
  `kubernetes.io/metadata.name` on `var.namespace`, so the two names must
  agree.
