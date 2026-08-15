environment = "prototype"

# The Azure Storage state home. The foundation states this stack reads back are
# addressed by convention — foundations/<cloud>/prototype.tfstate in this same
# account and container — so there are no per-cloud coordinates to keep in sync
# with foundations/<cloud>/backend/prototype.hcl.
state_home = {
  resource_group_name  = "rg-onek8s-tfstate"
  storage_account_name = "onek8stfstate"
  container_name       = "tfstate"
}

# Every namespace below enforces Pod Security Admission at "restricted" without
# saying so: that is the module's default, on every cloud. Add
# `pod_security = { enforce = "baseline" }` to a tenant to record an exception,
# and expect to justify it in the pull request.
#
# Every tenant of this environment, on every cloud, in one apply. The syntax is
# identical on every cloud: only "cloud" differs. Map keys must be unique, so
# the same tenant name on several clouds is keyed <cloud>-<tenant> with an
# explicit "name" (that name is what the namespace and secret prefix use).
tenants = {
  azure-team-alpha = {
    cloud = "azure"
    name  = "team-alpha"
    quota = {
      cpu_requests    = "2"
      cpu_limits      = "4"
      memory_requests = "4Gi"
      memory_limits   = "8Gi"
    }
    labels = { "onek8s.io/cost-center" = "alpha-1001" }
  }
  azure-team-beta = {
    cloud = "azure"
    name  = "team-beta"
  }

  aws-team-alpha = {
    cloud = "aws"
    name  = "team-alpha"
    quota = {
      cpu_requests    = "2"
      cpu_limits      = "4"
      memory_requests = "4Gi"
      memory_limits   = "8Gi"
    }
    labels = { "onek8s.io/cost-center" = "alpha-1001" }
  }
  aws-team-beta = {
    cloud = "aws"
    name  = "team-beta"
  }

  gcp-team-alpha = {
    cloud = "gcp"
    name  = "team-alpha"
    quota = {
      cpu_requests    = "2"
      cpu_limits      = "4"
      memory_requests = "4Gi"
      memory_limits   = "8Gi"
    }
    labels = { "onek8s-io-cost-center" = "alpha-1001" }
  }
  gcp-team-beta = {
    cloud = "gcp"
    name  = "team-beta"
  }

  oci-team-alpha = {
    cloud = "oci"
    name  = "team-alpha"
    quota = {
      cpu_requests    = "2"
      cpu_limits      = "4"
      memory_requests = "4Gi"
      memory_limits   = "8Gi"
    }
    labels = { "onek8s.io/cost-center" = "alpha-1001" }
  }
  oci-team-beta = {
    cloud = "oci"
    name  = "team-beta"
  }
}
