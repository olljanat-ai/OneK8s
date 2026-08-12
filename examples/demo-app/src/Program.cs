// OneK8s demo app: proves that a tenant workload can reach the shared
// secret backend ("vault") and the shared managed Redis using nothing but
// its workload identity — no passwords or connection strings are configured
// anywhere. The same binary runs on all three clouds; CLOUD selects the
// implementation. Secret and Redis values are rendered as PLAIN TEXT in the
// UI on purpose: this is a demo, never do that in a real app.

using System.Net;
using System.Security.Cryptography;
using System.Text;
using Amazon.Runtime;
using Amazon.SecretsManager;
using Amazon.SecretsManager.Model;
using Azure.Identity;
using Azure.Security.KeyVault.Secrets;
using Google.Apis.Auth.OAuth2;
using Google.Cloud.SecretManager.V1;
using Microsoft.Azure.StackExchangeRedis;
using StackExchange.Redis;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

var cfg = DemoConfig.FromEnvironment();

app.MapGet("/healthz", () => Results.Text("ok"));

app.MapGet("/", async () =>
{
    var secret = await DemoResult.RunAsync(() => ReadSecretAsync(cfg));
    var redis = await DemoResult.RunAsync(() => RedisRoundTripAsync(cfg));
    return Results.Content(RenderHtml(cfg, secret, redis), "text/html");
});

app.Run();

// --- Vault access ------------------------------------------------------------
// Reads the hardcoded demo secret through the tenant's workload identity.
// The per-cloud naming contract matches the platform's secret prefix scoping:
//   azure/gcp: "<tenant>-demo-secret"     aws: "<env>/<tenant>/demo-secret"
static async Task<KeyValuePair<string, string>> ReadSecretAsync(DemoConfig cfg)
{
    switch (cfg.Cloud)
    {
        case "azure":
        {
            var name = $"{cfg.Tenant}-{cfg.SecretBaseName}";
            var client = new SecretClient(new Uri(cfg.Require(cfg.KeyVaultUri, "AZURE_KEY_VAULT_URI")), new DefaultAzureCredential());
            var secret = await client.GetSecretAsync(name);
            return new(name, secret.Value.Value);
        }
        case "aws":
        {
            var name = $"{cfg.Environment}/{cfg.Tenant}/{cfg.SecretBaseName}";
            using var client = new AmazonSecretsManagerClient();
            var secret = await client.GetSecretValueAsync(new GetSecretValueRequest { SecretId = name });
            return new(name, secret.SecretString);
        }
        case "gcp":
        {
            var name = $"{cfg.Tenant}-{cfg.SecretBaseName}";
            var client = await SecretManagerServiceClient.CreateAsync();
            var version = new SecretVersionName(cfg.Require(cfg.GcpProjectId, "GCP_PROJECT_ID"), name, "latest");
            var secret = await client.AccessSecretVersionAsync(version);
            return new(name, secret.Payload.Data.ToStringUtf8());
        }
        default:
            throw new InvalidOperationException($"CLOUD must be azure, aws or gcp (got \"{cfg.Cloud}\").");
    }
}

// --- Redis access ------------------------------------------------------------
// Connects to the shared managed Redis (endpoint published by the platform's
// "redis-connection" ConfigMap), writes the hardcoded demo key and reads it
// back. The AUTH "password" is always a short-lived token minted from the
// workload identity.
static async Task<KeyValuePair<string, string>> RedisRoundTripAsync(DemoConfig cfg)
{
    var options = new ConfigurationOptions();
    options.EndPoints.Add(cfg.Require(cfg.RedisHost, "REDIS_HOST"), cfg.RedisPort);
    options.Ssl = cfg.RedisTls;

    switch (cfg.Cloud)
    {
        case "azure":
            // Azure Managed Redis: Entra ID auth (username = identity object
            // ID, password = Entra token) — handled by the extension, which
            // also re-authenticates before the token expires.
            await options.ConfigureForAzureWithTokenCredentialAsync(new DefaultAzureCredential());
            break;
        case "aws":
            // ElastiCache IAM auth: the password is a SigV4-presigned URL for
            // the cache name, signed with the IRSA role credentials.
            var immutable = await FallbackCredentialsFactory.GetCredentials().GetCredentialsAsync();
            options.User = cfg.Require(cfg.RedisUsername, "REDIS_USERNAME");
            options.Password = ElastiCacheIamAuth.GenerateToken(
                cfg.Require(cfg.RedisCacheName, "REDIS_CACHE_NAME"),
                cfg.RedisUsername!,
                cfg.Require(cfg.AwsRegion, "AWS_REGION"),
                immutable);
            break;
        case "gcp":
            // Memorystore IAM auth: password = ADC access token of the tenant
            // GSA (via GKE Workload Identity), user stays "default".
            var credential = (await GoogleCredential.GetApplicationDefaultAsync())
                .CreateScoped("https://www.googleapis.com/auth/cloud-platform");
            options.Password = await credential.UnderlyingCredential.GetAccessTokenForRequestAsync();
            // DEMO ONLY: Memorystore serves a cert from a cluster-private CA
            // (fetch it via the clusters.getCertificateAuthority API and trust
            // it properly in real code). The endpoint is a PSC address that is
            // only reachable from inside the VPC.
            options.CertificateValidation += (_, _, _, _) => true;
            break;
        default:
            throw new InvalidOperationException($"CLOUD must be azure, aws or gcp (got \"{cfg.Cloud}\").");
    }

    // A per-request connection keeps the demo simple and sidesteps auth-token
    // expiry; real apps share one multiplexer and refresh credentials.
    await using var mux = await ConnectionMultiplexer.ConnectAsync(options);
    var db = mux.GetDatabase();

    // On AWS the ACL only allows the tenant's "<tenant>:" key slice, so the
    // prefix from the ConfigMap is mandatory there; it is empty elsewhere.
    var key = $"{cfg.RedisKeyPrefix}demo-key";
    var value = $"Hello from {cfg.Tenant} on {cfg.Cloud} at {DateTime.UtcNow:O}";
    await db.StringSetAsync(key, value, TimeSpan.FromMinutes(10));
    var readBack = await db.StringGetAsync(key);
    return new(key, readBack.ToString());
}

// --- UI ----------------------------------------------------------------------
static string RenderHtml(DemoConfig cfg, DemoResult secret, DemoResult redis)
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
        <p>Vault and Redis access below uses <strong>only the workload identity</strong>
        of ServiceAccount <code>{{E(cfg.Tenant)}}/workload</code> — no credentials are
        configured in this app. Values are shown in plain text for demo purposes.</p>
        <table>
          <tr><td>Cloud / tenant / env</td><td><code>{{E(cfg.Cloud)}} / {{E(cfg.Tenant)}} / {{E(cfg.Environment)}}</code></td></tr>
          {{Row("Vault secret", secret)}}
          <tr><td>Redis endpoint</td><td><code>{{E(cfg.RedisHost)}}:{{cfg.RedisPort}}</code> (TLS: {{cfg.RedisTls}})</td></tr>
          {{Row("Redis key", redis)}}
        </table>
        </body></html>
        """;
}

// --- Plumbing ----------------------------------------------------------------
sealed record DemoConfig(
    string Cloud, string Tenant, string Environment, string SecretBaseName,
    string? KeyVaultUri, string? GcpProjectId, string? AwsRegion,
    string? RedisHost, int RedisPort, bool RedisTls, string? RedisUsername,
    string RedisKeyPrefix, string? RedisCacheName)
{
    public static DemoConfig FromEnvironment()
    {
        static string? Get(string name) => System.Environment.GetEnvironmentVariable(name);
        return new(
            Cloud: (Get("CLOUD") ?? "azure").ToLowerInvariant(),
            Tenant: Get("TENANT_NAME") ?? "team-alpha",
            Environment: Get("ENVIRONMENT") ?? "dev",
            SecretBaseName: Get("DEMO_SECRET_NAME") ?? "demo-secret",
            KeyVaultUri: Get("AZURE_KEY_VAULT_URI"),
            GcpProjectId: Get("GCP_PROJECT_ID"),
            AwsRegion: Get("AWS_REGION") ?? Get("AWS_DEFAULT_REGION"),
            RedisHost: Get("REDIS_HOST"),
            RedisPort: int.TryParse(Get("REDIS_PORT"), out var p) ? p : 6379,
            RedisTls: !string.Equals(Get("REDIS_TLS"), "false", StringComparison.OrdinalIgnoreCase),
            RedisUsername: Get("REDIS_USERNAME"),
            RedisKeyPrefix: Get("REDIS_KEY_PREFIX") ?? "",
            RedisCacheName: Get("REDIS_CACHE_NAME"));
    }

    public string Require(string? value, string envVar) =>
        !string.IsNullOrEmpty(value) ? value : throw new InvalidOperationException($"Environment variable {envVar} is required on cloud \"{Cloud}\".");
}

sealed record DemoResult(KeyValuePair<string, string>? Value, string? Error)
{
    public static async Task<DemoResult> RunAsync(Func<Task<KeyValuePair<string, string>>> action)
    {
        try { return new(await action(), null); }
        catch (Exception ex) { return new(null, ex.Message); }
    }
}

// ElastiCache IAM auth tokens are SigV4-presigned URLs (scheme stripped) for
// "<cache-name>/?Action=connect&User=<user-id>", valid for 15 minutes.
// There is no official .NET helper, so this signs one by hand.
static class ElastiCacheIamAuth
{
    public static string GenerateToken(string cacheName, string userId, string region, ImmutableCredentials creds)
    {
        var now = DateTime.UtcNow;
        var amzDate = now.ToString("yyyyMMddTHHmmssZ");
        var dateStamp = now.ToString("yyyyMMdd");
        var scope = $"{dateStamp}/{region}/elasticache/aws4_request";

        var query = new SortedDictionary<string, string>(StringComparer.Ordinal)
        {
            ["Action"] = "connect",
            ["User"] = userId,
            ["X-Amz-Algorithm"] = "AWS4-HMAC-SHA256",
            ["X-Amz-Credential"] = $"{creds.AccessKey}/{scope}",
            ["X-Amz-Date"] = amzDate,
            ["X-Amz-Expires"] = "900",
            ["X-Amz-SignedHeaders"] = "host",
        };
        if (!string.IsNullOrEmpty(creds.Token))
            query["X-Amz-Security-Token"] = creds.Token;

        var canonicalQuery = string.Join("&", query.Select(kv => $"{UriEncode(kv.Key)}={UriEncode(kv.Value)}"));
        var canonicalRequest = $"GET\n/\n{canonicalQuery}\nhost:{cacheName}\n\nhost\nUNSIGNED-PAYLOAD";
        var stringToSign = $"AWS4-HMAC-SHA256\n{amzDate}\n{scope}\n{Hex(SHA256.HashData(Encoding.UTF8.GetBytes(canonicalRequest)))}";

        var signingKey = Encoding.UTF8.GetBytes("AWS4" + creds.SecretKey);
        foreach (var part in new[] { dateStamp, region, "elasticache", "aws4_request" })
            signingKey = HMACSHA256.HashData(signingKey, Encoding.UTF8.GetBytes(part));
        var signature = Hex(HMACSHA256.HashData(signingKey, Encoding.UTF8.GetBytes(stringToSign)));

        return $"{cacheName}/?{canonicalQuery}&X-Amz-Signature={signature}";
    }

    private static string Hex(byte[] bytes) => Convert.ToHexString(bytes).ToLowerInvariant();

    // RFC 3986 percent-encoding, as SigV4 requires (Uri.EscapeDataString is
    // close but documented behavior varies across runtimes for a few chars).
    private static string UriEncode(string value)
    {
        const string unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
        var sb = new StringBuilder(value.Length);
        foreach (var b in Encoding.UTF8.GetBytes(value))
            if (unreserved.Contains((char)b)) sb.Append((char)b);
            else sb.Append('%').Append(b.ToString("X2"));
        return sb.ToString();
    }
}
