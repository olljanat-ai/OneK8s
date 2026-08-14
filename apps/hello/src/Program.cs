using System.Net;

// A deliberately tiny ASP.NET Core app whose only job is to prove two things
// about whichever cluster it landed on: that the platform's ingress reached it,
// and that External Secrets handed it a secret out of *that* cloud's secret
// backend. Everything it shows comes from the environment, so one image runs
// unchanged on AKS, EKS, GKE and OKE.
var builder = WebApplication.CreateSlimBuilder(args);
var app = builder.Build();

app.MapGet("/healthz", () => Results.Text("ok"));

app.MapGet("/", () => Results.Content(Render(), "text/html; charset=utf-8"));

app.Run();

// The secret is read per request rather than captured at startup. It arrives
// as a Secret volume, which the kubelet refreshes in place, so a value that
// External Secrets syncs *after* the pod started shows up without a restart —
// an environment variable would have been frozen at exec time. The file is
// absent (not empty) until the sync succeeds, which is the "not available"
// case the page renders.
static string? ReadSecret()
{
    var path = Value("TEST_SECRET_FILE");

    if (path is null)
    {
        return Value("TEST_SECRET");
    }

    try
    {
        return File.Exists(path) ? File.ReadAllText(path).TrimEnd('\r', '\n') : null;
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException)
    {
        return null;
    }
}

// Unset and set-but-empty are the same thing here: both mean "the chart did not
// give us one".
static string? Value(string name) =>
    Environment.GetEnvironmentVariable(name) is { Length: > 0 } value ? value : null;

static string Encode(string? value) => WebUtility.HtmlEncode(value ?? string.Empty);

static string Render()
{
    var secretName = Value("TEST_SECRET_NAME") ?? "test";
    var secret = ReadSecret();

    // Already-encoded HTML either way: a placeholder element, or the secret's
    // value escaped. Whatever is in the vault is untrusted input to this page.
    var secretCell = secret is null
        ? """<span class="pending">not available &mdash; External Secrets has not synced it yet</span>"""
        : Encode(secret);

    return $$"""
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>OneK8s hello</title>
        <style>
          :root { color-scheme: dark; }
          body { margin: 0; padding: 3rem 1.5rem; background: #0b1220; color: #e2e8f0;
                 font-family: system-ui, -apple-system, "Segoe UI", sans-serif; line-height: 1.5; }
          main { max-width: 42rem; margin: 0 auto; }
          h1 { margin: 0 0 2rem; font-size: 1.6rem; font-weight: 600; }
          dl { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: .6rem 1.5rem; margin: 0; }
          dt { color: #94a3b8; }
          dd { margin: 0; overflow-wrap: anywhere;
               font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
          .pending { color: #fbbf24; font-family: inherit; }
          footer { margin-top: 2.5rem; color: #64748b; font-size: .85rem; }
        </style>
        </head>
        <body>
        <main>
          <h1>{{Encode(Value("WELCOME_MESSAGE") ?? "Welcome to OneK8s!")}}</h1>
          <dl>
            <dt>Cloud</dt><dd>{{Encode(Value("CLOUD") ?? "unknown")}}</dd>
            <dt>Environment</dt><dd>{{Encode(Value("ENVIRONMENT") ?? "unknown")}}</dd>
            <dt>Namespace</dt><dd>{{Encode(Value("POD_NAMESPACE") ?? "unknown")}}</dd>
            <dt>Pod</dt><dd>{{Encode(Value("POD_NAME") ?? Environment.MachineName)}}</dd>
            <dt>Secret &quot;{{Encode(secretName)}}&quot;</dt><dd>{{secretCell}}</dd>
          </dl>
          <footer>Served by .NET {{Encode(Environment.Version.ToString())}}.</footer>
        </main>
        </body>
        </html>
        """;
}
