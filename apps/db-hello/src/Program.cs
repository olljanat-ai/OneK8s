using System.Data;
using System.Net;
using System.Text;
using Azure.Core;
using Azure.Identity;
using Microsoft.Data.SqlClient;

// The second example workload, and the one that holds no secret at all.
//
// hello proves that External Secrets handed the pod a value out of the cloud's
// secret backend. This one goes a step further and removes the value: it talks
// to Azure SQL as the *tenant's own managed identity*, with a token it mints
// from the ServiceAccount token Kubernetes projects into the pod. There is no
// connection string in a Secret, no password in the chart and no credential in
// the image — the two configuration values it takes are a host name and a
// database name, both of them public.
//
//   /var/run/secrets/azure/tokens/azure-identity-token   (projected, rotated)
//        │ federated credential: system:serviceaccount:<tenant>:workload
//        ▼
//   Entra ID  ──access token for https://database.windows.net/──▶  Azure SQL
var builder = WebApplication.CreateSlimBuilder(args);
var app = builder.Build();

app.MapGet("/healthz", () => Results.Text("ok"));

app.MapGet("/", async (CancellationToken ct) =>
    Results.Content(await Page.RenderAsync(ct), "text/html; charset=utf-8"));

// The same platform mark the hello application serves, for the same reasons:
// held as a string because the image ships no wwwroot, and linked by the
// document so no browser falls back to asking for /favicon.ico.
const string Favicon = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
      <rect width="32" height="32" rx="7" fill="#0b1220"/>
      <path fill="#38bdf8" d="M16 2.5 26.55 7.58 29.16 19 21.86 28.16H10.14L2.84 19 5.45 7.58Z"/>
      <path fill="none" stroke="#0b1220" stroke-width="4.2" stroke-linecap="round"
            stroke-linejoin="round" d="M11.9 12.2 16 8.6V23.4M10.6 23.4h10.8"/>
    </svg>
    """;

app.MapGet("/favicon.svg", (HttpContext http) =>
{
    http.Response.Headers.CacheControl = "public, max-age=86400";
    return Results.Content(Favicon, "image/svg+xml; charset=utf-8");
});

app.Run();

/// <summary>Configuration, all of it from the environment.</summary>
static class Env
{
    // Unset and set-but-empty are the same thing here: both mean "the chart
    // did not give us one".
    public static string? Value(string name) =>
        Environment.GetEnvironmentVariable(name) is { Length: > 0 } value ? value : null;
}

record Visit(DateTime VisitedAt, string Pod, string Cloud);

record Session(string Login, string User, string Roles, IReadOnlyList<Visit> Visits);

/// <summary>
/// What the page can say about the database: a Session when the round trip
/// worked, otherwise the two-part sentence to print in its place.
/// </summary>
record Result(Session? Session, string? Problem, string? Detail);

static class Db
{
    // Built once: the credential caches the tokens it mints, so a page view
    // that follows another inside the hour does not go back to Entra ID.
    //
    // WorkloadIdentityCredential when the pod carries a federated token — the
    // AZURE_* variables and the token file are injected by the AKS workload
    // identity webhook, which the chart triggers with the
    // "azure.workload.identity/use" pod label. DefaultAzureCredential
    // otherwise, which is what makes `dotnet run` work after an `az login`.
    private static readonly TokenCredential Credential =
        Env.Value("AZURE_FEDERATED_TOKEN_FILE") is not null
            ? new WorkloadIdentityCredential()
            : new DefaultAzureCredential();

    // The audience is the SQL service, not the database: one token opens any
    // database this identity has a user in.
    private static readonly string[] Scope = ["https://database.windows.net/.default"];

    /// <summary>
    /// One round trip: record this page view, then read back who we are and
    /// the last few views. The INSERT is what proves the identity holds
    /// db_datawriter and not merely read access — and those rows are the only
    /// state this application has.
    /// </summary>
    public static async Task<Result> LoadAsync(CancellationToken ct)
    {
        if (Env.Value("SQL_SERVER") is null || Env.Value("SQL_DATABASE") is null)
        {
            return new Result(null, "not configured",
                "SQL_SERVER and SQL_DATABASE are unset; the chart requires both.");
        }

        AccessToken token;

        try
        {
            token = await Credential.GetTokenAsync(new TokenRequestContext(Scope), ct);
        }
        catch (Exception e) when (e is CredentialUnavailableException or AuthenticationFailedException)
        {
            return new Result(null, "no token",
                $"Entra ID would not issue a token for this pod's identity. {e.Message}");
        }

        // Three attempts, because "the database is asleep" is an ordinary
        // state for a free-offer database and not an error worth showing.
        // Anything the server says about permissions is final and not retried.
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                return new Result(await QueryAsync(token, ct), null, null);
            }
            catch (SqlException e) when (IsTransient(e) && attempt < 3)
            {
                await Task.Delay(TimeSpan.FromSeconds(5), ct);
            }
            catch (SqlException e)
            {
                return Explain(e);
            }
        }
    }

    private static string ConnectionString() =>
        new SqlConnectionStringBuilder
        {
            DataSource = $"tcp:{Env.Value("SQL_SERVER")},1433",
            InitialCatalog = Env.Value("SQL_DATABASE") ?? string.Empty,
            Encrypt = true,
            TrustServerCertificate = false,
            // A serverless database that has auto-paused takes up to a minute
            // to wake, and the first connection is the one that waits for it.
            ConnectTimeout = int.TryParse(Env.Value("SQL_CONNECT_TIMEOUT_SECONDS"), out var t) ? t : 30,
            ApplicationName = "onek8s-db-hello",
        }.ConnectionString;

    private static async Task<Session> QueryAsync(AccessToken token, CancellationToken ct)
    {
        await using var connection = new SqlConnection(ConnectionString())
        {
            // The whole point: a token, not a password. SqlClient puts it in
            // the login packet and the server validates it against Entra ID.
            AccessToken = token.Token,
        };

        await connection.OpenAsync(ct);

        await using var command = new SqlCommand(
            """
            INSERT INTO dbo.visits (pod, cloud) VALUES (@pod, @cloud);

            SELECT SUSER_SNAME() AS login_name,
                   USER_NAME()   AS user_name,
                   ISNULL((SELECT STRING_AGG(r.name, ', ')
                           FROM sys.database_role_members AS m
                                INNER JOIN sys.database_principals AS r
                                    ON r.principal_id = m.role_principal_id
                           WHERE m.member_principal_id = DATABASE_PRINCIPAL_ID()), '') AS roles;

            SELECT TOP (10) visited_at, pod, cloud FROM dbo.visits ORDER BY id DESC;
            """, connection);

        command.Parameters.Add("@pod", SqlDbType.NVarChar, 128).Value =
            Env.Value("POD_NAME") ?? Environment.MachineName;
        command.Parameters.Add("@cloud", SqlDbType.NVarChar, 32).Value =
            Env.Value("CLOUD") ?? "unknown";

        await using var reader = await command.ExecuteReaderAsync(ct);

        await reader.ReadAsync(ct);
        var login = reader.GetString(0);
        var user = reader.GetString(1);
        var roles = reader.GetString(2);

        var visits = new List<Visit>();
        await reader.NextResultAsync(ct);

        while (await reader.ReadAsync(ct))
        {
            visits.Add(new Visit(reader.GetDateTime(0), reader.GetString(1), reader.GetString(2)));
        }

        return new Session(login, user, roles.Length > 0 ? roles : "(none)", visits);
    }

    // Azure SQL's own "try again" conditions, plus the two a resume produces:
    // 40613 while the database wakes, -2 if the client gave up first.
    private static bool IsTransient(SqlException e) =>
        e.Number is 40613 or 40197 or 40501 or 49918 or 49919 or 49920 or 4060 or 10928 or 10929 or -2;

    // The failures worth naming, because each has a different fix and all of
    // them are ordinary states of a platform being set up.
    private static Result Explain(SqlException e) => e.Number switch
    {
        18456 => new Result(null, "no database user",
            "This identity authenticated to Entra ID but has no user in the database. Run the Bootstrap SQL workflow for this tenant."),
        229 or 230 => new Result(null, "not authorized",
            "The database user exists but is missing db_datareader/db_datawriter. Re-run the Bootstrap SQL workflow."),
        208 => new Result(null, "no schema",
            "The dbo.visits table does not exist yet — the Bootstrap SQL workflow creates it."),
        40613 => new Result(null, "resuming",
            "The database is waking up from auto-pause; reload in a moment."),
        _ => new Result(null, "unavailable", $"{e.Message} (error {e.Number})"),
    };
}

static class Page
{
    private static string Encode(string? value) => WebUtility.HtmlEncode(value ?? string.Empty);

    public static async Task<string> RenderAsync(CancellationToken ct)
    {
        var result = await Db.LoadAsync(ct);
        var session = result.Session;

        // Already-encoded HTML either way: the database user's name, or the
        // reason there is not one to show.
        var user = session is null
            ? $"""<span class="pending">{Encode(result.Problem)} &mdash; {Encode(result.Detail)}</span>"""
            : Encode(session.User);

        var visits = new StringBuilder();

        if (session is null)
        {
            visits.Append("""<tr><td colspan="3" class="pending">no rows &mdash; the database was not reachable</td></tr>""");
        }
        else if (session.Visits.Count == 0)
        {
            visits.Append("""<tr><td colspan="3" class="pending">no rows yet</td></tr>""");
        }
        else
        {
            foreach (var visit in session.Visits)
            {
                visits.Append($"<tr><td>{Encode(visit.VisitedAt.ToString("u"))}</td>")
                      .Append($"<td>{Encode(visit.Pod)}</td>")
                      .Append($"<td>{Encode(visit.Cloud)}</td></tr>");
            }
        }

        return $$"""
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>OneK8s db-hello</title>
            <link rel="icon" href="/favicon.svg" type="image/svg+xml">
            <style>
              :root { color-scheme: dark; }
              body { margin: 0; padding: 3rem 1.5rem; background: #0b1220; color: #e2e8f0;
                     font-family: system-ui, -apple-system, "Segoe UI", sans-serif; line-height: 1.5; }
              main { max-width: 46rem; margin: 0 auto; }
              h1 { margin: 0 0 2rem; font-size: 1.6rem; font-weight: 600; }
              h2 { margin: 2.5rem 0 .8rem; font-size: 1rem; font-weight: 600; color: #94a3b8; }
              dl { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: .6rem 1.5rem; margin: 0; }
              dt { color: #94a3b8; }
              dd { margin: 0; overflow-wrap: anywhere;
                   font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
              table { width: 100%; border-collapse: collapse;
                      font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .9rem; }
              th { text-align: left; color: #94a3b8; font-weight: 400; font-family: system-ui, sans-serif; }
              th, td { padding: .35rem .75rem .35rem 0; border-bottom: 1px solid #1e293b; overflow-wrap: anywhere; }
              .pending { color: #fbbf24; font-family: inherit; }
              footer { margin-top: 2.5rem; color: #64748b; font-size: .85rem; }
            </style>
            </head>
            <body>
            <main>
              <h1>{{Encode(Env.Value("WELCOME_MESSAGE") ?? "Welcome to OneK8s!")}}</h1>
              <dl>
                <dt>Cloud</dt><dd>{{Encode(Env.Value("CLOUD") ?? "unknown")}}</dd>
                <dt>Environment</dt><dd>{{Encode(Env.Value("ENVIRONMENT") ?? "unknown")}}</dd>
                <dt>Namespace</dt><dd>{{Encode(Env.Value("POD_NAMESPACE") ?? "unknown")}}</dd>
                <dt>Pod</dt><dd>{{Encode(Env.Value("POD_NAME") ?? Environment.MachineName)}}</dd>
              </dl>
              <h2>Azure SQL, without a password</h2>
              <dl>
                <dt>Server</dt><dd>{{Encode(Env.Value("SQL_SERVER") ?? "unset")}}</dd>
                <dt>Database</dt><dd>{{Encode(Env.Value("SQL_DATABASE") ?? "unset")}}</dd>
                <dt>Workload identity</dt><dd>{{Encode(Env.Value("AZURE_CLIENT_ID") ?? "none injected")}}</dd>
                <dt>Signed in as</dt><dd>{{Encode(session?.Login)}}</dd>
                <dt>Database user</dt><dd>{{user}}</dd>
                <dt>Database roles</dt><dd>{{Encode(session?.Roles)}}</dd>
              </dl>
              <h2>Last 10 page views, read back out of the database</h2>
              <table>
                <thead><tr><th>Visited (UTC)</th><th>Pod</th><th>Cloud</th></tr></thead>
                <tbody>{{visits}}</tbody>
              </table>
              <footer>Served by .NET {{Encode(Environment.Version.ToString())}}. Every page view is a row.</footer>
            </main>
            </body>
            </html>
            """;
    }
}
