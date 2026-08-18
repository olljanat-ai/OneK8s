environment = "prototype"

# The Azure Storage state home. The foundation states this stack reads back are
# addressed by convention — foundations/<cloud>/prototype.tfstate in this same
# account and container — so there are no per-cloud coordinates to keep in sync
# with foundations/<cloud>/backend/prototype.hcl. The hub's own state
# (foundations/azure) is read the same way.
state_home = {
  resource_group_name  = "rg-onek8s-tfstate"
  storage_account_name = "onek8stfstate"
  container_name       = "tfstate"
}

# Clusters registered with the Argo CD hub on AKS, keyed by cloud. Azure is
# never listed: Argo CD already has the in-cluster entry for the cluster it
# runs on.
#
# The prototype spokes are unrestricted — no namespace list, cluster-scoped
# resources allowed — because this environment is where platform-wide
# manifests get tried out. Narrow a spoke with
# `namespaces = [...]` + `cluster_resources = false`, which binds the manager
# ServiceAccount per namespace instead of cluster-wide.
#
# AWS is not just any spoke here: it is where the hello application's
# production stage runs, so removing it from this map removes production
# (the ApplicationSet's cluster generator finds no cluster and generates no
# Application) rather than breaking anything. Kargo's production Stage stays,
# with nothing to promote onto — it is the release path, not the cluster.
spokes = {
  aws = {}
}

# The root Application: the only Argo CD object Terraform creates. It points
# Argo CD at the OneK8s-argocd repository, and everything from there down — the
# AppProject, the ApplicationSets, and every Application they generate on the
# hub and on each spoke — is Git, not Terraform.
#
# Two repositories, because they change for different reasons:
#
#   repo_url       OneK8s-argocd  where and when an application is deployed
#                                 (the Kargo Warehouse and Stages: staging on
#                                 Azure, production on AWS behind a manual
#                                 promotion, and the revision each one runs)
#   apps_repo_url  OneK8s-hello   what is deployed: the applications and their
#                                 charts
#
# The values below are what make one copy of that chart serve every
# environment: they are handed to it as Helm values, so the spoke selector, the
# hosts and the tenant follow the environment rather than being committed per
# environment.
platform_apps = {
  repo_url             = "https://github.com/olljanat-ai/OneK8s-argocd.git"
  target_revision      = "main"
  apps_repo_url        = "https://github.com/olljanat-ai/OneK8s-hello.git"
  apps_target_revision = "main"

  # Where the example applications land. team-alpha exists on all four clouds
  # in this environment (tenants/envs/prototype.tfvars), and its namespaced
  # SecretStore is what the hello app reads its test secret through.
  tenant = "team-alpha"

  # Application hosts are "<cloud>-<app>.onek8s.lol", one label deep, which is
  # all the platform wildcard covers. The cloud is the stage's: azure-hello is
  # staging, aws-hello is production.
  domain = "onek8s.lol"
}
