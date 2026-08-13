# -----------------------------------------------------------------------------
# The PKI the whole topology hangs off.
#
# argocd-agent authenticates agents with mTLS against a CA of its own — not a
# public one. That is what makes the design work here: the principal's endpoint
# is on the public internet because it has to be reachable from three clouds
# with no fixed egress addresses, but the only clients that get past the TLS
# handshake are the ones holding a certificate this CA signed, and the name on
# that certificate *is* the agent's identity. There is no shared secret to
# leak and no password to rotate.
#
# The project ships a CLI (argocd-agentctl) that generates all of this
# imperatively. It is not used here: the certificates are Terraform resources
# instead, so an expiring certificate is a plan diff rather than a runbook, and
# adding a spoke is one map entry rather than five commands run against two
# kubeconfigs. The secrets this produces are byte-for-byte what the CLI would
# have written — same names, same keys, same subject conventions — so
# argocd-agentctl still works for inspection and troubleshooting.
# -----------------------------------------------------------------------------

locals {
  hub_ns = var.hub_namespace

  # Kubernetes resolves a Service under all four of these; the certificate has
  # to cover whichever one the client happens to use.
  service_dns_names = { for service in ["argocd-agent-principal", "argocd-agent-resource-proxy", "argocd-agent-redis-proxy"] : service => [
    service,
    "${service}.${local.hub_ns}",
    "${service}.${local.hub_ns}.svc",
    "${service}.${local.hub_ns}.svc.cluster.local",
  ] }

  leaf_validity_hours = var.certificate_validity_days * 24
  leaf_renewal_hours  = var.certificate_renewal_days * 24
}

resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem = tls_private_key.ca.private_key_pem

  subject {
    common_name  = "argocd-agent-ca"
    organization = "OneK8s"
  }

  is_ca_certificate     = true
  validity_period_hours = var.ca_validity_days * 24

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]
}

# --- Principal gRPC server ---------------------------------------------------
# The one certificate that is presented across the public internet. Its SANs
# are every name an agent might dial it by, plus the in-cluster names so that
# anything on the hub side can talk to it too.
resource "tls_private_key" "principal" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_cert_request" "principal" {
  private_key_pem = tls_private_key.principal.private_key_pem

  subject {
    common_name  = "argocd-agent-principal"
    organization = "OneK8s"
  }

  dns_names = distinct(concat(
    ["localhost", local.principal_fqdn, local.principal_address],
    local.service_dns_names["argocd-agent-principal"],
    var.principal_extra_dns_names,
  ))

  ip_addresses = distinct(concat(["127.0.0.1"], var.principal_extra_ip_addresses))
}

resource "tls_locally_signed_cert" "principal" {
  cert_request_pem   = tls_cert_request.principal.cert_request_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem

  validity_period_hours = local.leaf_validity_hours
  early_renewal_hours   = local.leaf_renewal_hours

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
  ]
}

# --- Resource proxy ----------------------------------------------------------
# Never leaves the hub cluster: the hub's argocd-server talks to it to fetch
# live resources, and it forwards those requests down the agents' connections.
resource "tls_private_key" "resource_proxy" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_cert_request" "resource_proxy" {
  private_key_pem = tls_private_key.resource_proxy.private_key_pem

  subject {
    common_name  = "argocd-agent-resource-proxy"
    organization = "OneK8s"
  }

  dns_names    = concat(["localhost"], local.service_dns_names["argocd-agent-resource-proxy"])
  ip_addresses = ["127.0.0.1"]
}

resource "tls_locally_signed_cert" "resource_proxy" {
  cert_request_pem   = tls_cert_request.resource_proxy.cert_request_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem

  validity_period_hours = local.leaf_validity_hours
  early_renewal_hours   = local.leaf_renewal_hours

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
  ]
}

# --- Redis proxy -------------------------------------------------------------
# Also hub-local. It sits in front of the hub's redis and splits reads: keys
# belonging to an agent are answered from that agent's cache over gRPC,
# everything else from the hub's own redis.
resource "tls_private_key" "redis_proxy" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_cert_request" "redis_proxy" {
  private_key_pem = tls_private_key.redis_proxy.private_key_pem

  subject {
    common_name  = "argocd-agent-redis-proxy"
    organization = "OneK8s"
  }

  dns_names    = concat(["localhost"], local.service_dns_names["argocd-agent-redis-proxy"])
  ip_addresses = ["127.0.0.1"]
}

resource "tls_locally_signed_cert" "redis_proxy" {
  cert_request_pem   = tls_cert_request.redis_proxy.cert_request_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem

  validity_period_hours = local.leaf_validity_hours
  early_renewal_hours   = local.leaf_renewal_hours

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
  ]
}

# --- Agent client certificates ----------------------------------------------
# One per spoke. The common name is the agent's name, and the principal is
# configured to read the agent's identity straight out of it
# (auth = "mtls:CN=([^,]+)"), so the certificate is both the credential and the
# claim of who is presenting it. A spoke cannot impersonate another spoke
# without a certificate this CA signed for that name.
resource "tls_private_key" "agent" {
  for_each = local.agents

  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_cert_request" "agent" {
  for_each = local.agents

  private_key_pem = tls_private_key.agent[each.key].private_key_pem

  subject {
    common_name  = each.value.name
    organization = "OneK8s"
  }
}

resource "tls_locally_signed_cert" "agent" {
  for_each = local.agents

  cert_request_pem   = tls_cert_request.agent[each.key].cert_request_pem
  ca_private_key_pem = tls_private_key.ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca.cert_pem

  validity_period_hours = local.leaf_validity_hours
  early_renewal_hours   = local.leaf_renewal_hours

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "client_auth",
  ]
}

# --- JWT signing key ---------------------------------------------------------
# Separate from the PKI above: the principal signs the session tokens it issues
# to authenticated agents with this. PKCS#8, which is the encoding the
# principal expects to read out of the secret.
resource "tls_private_key" "jwt" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
