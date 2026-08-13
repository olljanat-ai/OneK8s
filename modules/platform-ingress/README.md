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
  extra_objects       = [/* SecretStore + ExternalSecret, or SecretProviderClass */]
}
```

## What it configures

| Concern | Setting |
|---|---|
| IngressClass | `traefik`, marked as the **cluster default**, so a tenant Ingress needs no `ingressClassName` |
| HTTP | `web` (:80) permanently redirects to `websecure` (:443) |
| TLS | `websecure` terminates TLS; the default `TLSStore` serves `platform-wildcard-tls` |
| Address | `Service` type `LoadBalancer`, annotated per cloud; Traefik publishes it into every Ingress' status |
| Dashboard | off — it would be an unauthenticated route on the public load balancer |

## The default certificate

The module does **not** fetch the certificate; it only points Traefik's
default `TLSStore` at `var.default_certificate_secret_name`. Filling that
secret is the caller's job and is the one genuinely cloud-shaped part, so it
is passed in as `extra_objects`:

- **AWS, GCP, OCI** — a platform `ServiceAccount`, a namespaced ESO
  `SecretStore` bound to it, and an `ExternalSecret` that materializes the
  distributed wildcard (`tls.crt` + `tls.key` in one JSON value) as a
  `kubernetes.io/tls` secret.
- **Azure** — a `SecretProviderClass`; the Secrets Store CSI driver mounts the
  Key Vault certificate into the Traefik pod and syncs it into the same
  secret, so the private key never passes through Terraform state.

Both paths converge on one Kubernetes TLS secret, which is why the Traefik
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

## Notes

- `extra_objects` is rendered through the chart's `extraObjects`, which passes
  each manifest through Go templating. Nothing here uses template syntax, but
  a caller that adds `{{ … }}` should expect it to be evaluated.
- ESO objects in `extra_objects` need the External Secrets CRDs to exist when
  the release is applied. Callers order that with `depends_on` on the ESO
  release rather than by using `kubernetes_manifest`, which would need the
  CRDs at *plan* time — before the foundation has ever been applied.
- Reaching a tenant workload also needs the tenant's NetworkPolicy to allow
  this namespace; `modules/tenant-namespace` does that by matching
  `kubernetes.io/metadata.name` on `var.namespace`, so the two names must
  agree.
