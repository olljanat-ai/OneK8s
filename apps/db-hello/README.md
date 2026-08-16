# db-hello

A minimal .NET 10 web application that reads and writes an **Azure SQL
Database** as the tenant's own managed identity. Its whole point is the
credential that is not there: no connection string in a Secret, no password in
the chart, nothing in the image.

```
apps/db-hello/
├── src/            # Program.cs + DbHello.csproj — one file, one page
├── Dockerfile      # SDK build → chiseled ASP.NET runtime
└── chart/          # what Argo CD renders on the hub
```

Every page view is a row: the app inserts one into `dbo.visits`, then reads the
last ten back and prints them, along with who the database thinks it is.

```
pod (SA: workload)
  │  projected token, audience api://AzureADTokenExchange
  ▼
Entra ID ── federated credential: system:serviceaccount:team-alpha:workload
  │  access token for https://database.windows.net/
  ▼
Azure SQL ── database user for the tenant's UAMI, db_datareader + db_datawriter
```

| Variable | Set by | Used for |
|---|---|---|
| `SQL_SERVER` / `SQL_DATABASE` | the ApplicationSet, from the foundation's outputs | where to connect |
| `SQL_CONNECT_TIMEOUT_SECONDS` | the chart | waiting out an auto-pause resume |
| `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_FEDERATED_TOKEN_FILE` | the AKS **workload identity webhook** | which identity, and the token to exchange |
| `CLOUD` / `ENVIRONMENT` | the ApplicationSet | shown on the page |
| `POD_NAME` / `POD_NAMESPACE` | the downward API | shown on the page, and written to the row |

The webhook only mutates a pod that carries the `azure.workload.identity/use`
label and runs as a ServiceAccount annotated with a client ID — the chart sets
the first, `modules/tenant-namespace/azure` sets the second. That is the entire
wiring; the application asks `Azure.Identity` for a token and hands it to
`SqlConnection.AccessToken`.

Three states are ordinary rather than errors, and the page names each one
instead of failing:

| What the page says | What it means |
|---|---|
| `resuming` | the free-tier database auto-paused; it is waking up (retried three times first) |
| `no database user` | the identity is fine, but nobody has run the **Bootstrap SQL** workflow for this tenant |
| `no schema` | the user exists but `dbo.visits` does not — same workflow |

`GET /healthz` is the liveness and readiness probe, and deliberately does
**not** touch the database: an auto-paused database must not restart the pod.

## Where it is deployed, and how

Argo CD, from `gitops/argocd/` — one Application, on the hub only, because the
database is an Azure resource and the identity is an Entra one. The full story
— the free offer, the bootstrap workflow, the DNS record, the known gaps — is
in [docs/db-hello-app.md](../../docs/db-hello-app.md).

## Running it locally

Anything `DefaultAzureCredential` accepts works, so an `az login` as a user
with a database user of its own is enough:

```bash
cd apps/db-hello/src
SQL_SERVER=sql-onek8s-prototype-ab12.database.windows.net \
SQL_DATABASE=appdb \
WELCOME_MESSAGE="Hello from my laptop" dotnet run
```

Your own address needs a firewall rule on the server (`sql_firewall_rules` in
the foundation, or `az sql server firewall-rule create`) — the cluster gets in
through the AKS subnet's service endpoint, which a laptop is not on.
