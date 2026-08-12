// OneK8s demo app: proves that a tenant workload can consume the shared
// secret backend ("vault") and the shared managed Redis WITHOUT any
// cloud-specific code or SDK. The platform does the cloud work:
//
//  - Vault:  an ExternalSecret syncs the hardcoded "demo-secret" (read from
//            the vault with the tenant's workload identity, prefix-scoped)
//            into K8s Secret "demo-secret" -> env DEMO_SECRET.
//  - Redis:  endpoint comes from the platform's "redis-connection"
//            ConfigMap; the AUTH password is itself a vault secret under the
//            tenant's prefix, synced by the platform's "redis-auth"
//            ExternalSecret -> env REDIS_PASSWORD.
//
// The same binary therefore runs unchanged on Azure, AWS and GCP. Secret and
// Redis values are rendered as PLAIN TEXT in the UI on purpose: this is a
// demo, never do that in a real app.

using System.Net;
using StackExchange.Redis;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var tenant = Env("TENANT_NAME") ?? "team-alpha";

app.MapGet("/healthz", () => Results.Text("ok"));

app.MapGet("/", async () =>
{
    var secret = DemoResult.Run(ReadSecret);
    var redis = await DemoResult.RunAsync(RedisRoundTripAsync);
    return Results.Content(RenderHtml(secret, redis), "text/html");
});

app.Run();

// --- Vault access (via the platform, not a cloud SDK) ------------------------
KeyValuePair<string, string> ReadSecret()
{
    var value = Env("DEMO_SECRET")
        ?? throw new InvalidOperationException(
            "env DEMO_SECRET is not set - is the demo-secret ExternalSecret applied and synced? (kubectl describe externalsecret demo-secret)");
    return new("demo-secret (via ExternalSecret)", value);
}

// --- Redis access ------------------------------------------------------------
async Task<KeyValuePair<string, string>> RedisRoundTripAsync()
{
    var options = new ConfigurationOptions();
    options.EndPoints.Add(Require("REDIS_HOST"), int.TryParse(Env("REDIS_PORT"), out var p) ? p : 6379);
    options.Ssl = !string.Equals(Env("REDIS_TLS"), "false", StringComparison.OrdinalIgnoreCase);
    options.Password = Require("REDIS_PASSWORD"); // synced by the redis-auth ExternalSecret
    if (Env("REDIS_USERNAME") is { Length: > 0 } user)
        options.User = user; // per-tenant ACL user on AWS; default user elsewhere

    await using var mux = await ConnectionMultiplexer.ConnectAsync(options);
    var db = mux.GetDatabase();

    // On AWS the ACL only allows the tenant's "<tenant>:" key slice, so the
    // prefix from the ConfigMap is mandatory there; it is empty elsewhere.
    var key = $"{Env("REDIS_KEY_PREFIX")}demo-key";
    var value = $"Hello from {tenant} at {DateTime.UtcNow:O}";
    await db.StringSetAsync(key, value, TimeSpan.FromMinutes(10));
    var readBack = await db.StringGetAsync(key);
    return new(key, readBack.ToString());
}

// --- UI ----------------------------------------------------------------------
string RenderHtml(DemoResult secret, DemoResult redis)
{
    static string E(string? s) => WebUtility.HtmlEncode(s ?? "");
    static string Row(string label, DemoResult r) => r.Error is null
        ? $"<tr><td>{label} name</td><td><code>{E(r.Value?.Key)}</code></td></tr>" +
          $"<tr><td>{label} value</td><td><code>{E(r.Value?.Value)}</code></td></tr>"
        : $"<tr><td>{label}</td><td class=\"err\">{E(r.Error)}</td></tr>";

    return $$"""
        <!doctype html>
        <html><head><title>OneK8s demo</title><style>
          body { font-family: system-ui, sans-serif; max-width: 60rem; margin: 2rem auto; }
          table { border-collapse: collapse; width: 100%; }
          td { border: 1px solid #ccc; padding: .5rem .75rem; vertical-align: top; }
          td:first-child { white-space: nowrap; font-weight: 600; }
          .err { color: #b00020; }
          code { word-break: break-all; }
        </style></head><body>
        <h1>OneK8s tenant demo</h1>
        <p>This app contains <strong>no cloud SDKs and no credentials</strong>. The
        platform reads the vault with tenant <code>{{E(tenant)}}</code>'s workload
        identity and delivers everything below as plain Kubernetes Secrets and
        ConfigMaps. Values are shown in plain text for demo purposes.</p>
        <table>
          <tr><td>Tenant / env</td><td><code>{{E(tenant)}} / {{E(Env("ENVIRONMENT") ?? "dev")}}</code></td></tr>
          {{Row("Vault secret", secret)}}
          <tr><td>Redis endpoint</td><td><code>{{E(Env("REDIS_HOST"))}}:{{E(Env("REDIS_PORT"))}}</code> (TLS: {{E(Env("REDIS_TLS") ?? "true")}})</td></tr>
          {{Row("Redis key", redis)}}
        </table>
        </body></html>
        """;
}

static string? Env(string name) => Environment.GetEnvironmentVariable(name);

static string Require(string name) => Env(name) is { Length: > 0 } v
    ? v
    : throw new InvalidOperationException($"env {name} is not set - are the redis-connection ConfigMap and redis-auth Secret present? (tenant needs redis_enabled = true)");

sealed record DemoResult(KeyValuePair<string, string>? Value, string? Error)
{
    public static DemoResult Run(Func<KeyValuePair<string, string>> action)
    {
        try { return new(action(), null); }
        catch (Exception ex) { return new(null, ex.Message); }
    }

    public static async Task<DemoResult> RunAsync(Func<Task<KeyValuePair<string, string>>> action)
    {
        try { return new(await action(), null); }
        catch (Exception ex) { return new(null, ex.Message); }
    }
}
