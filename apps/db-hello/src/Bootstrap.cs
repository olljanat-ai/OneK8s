using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using OneK8s.DbHello.Data;

namespace OneK8s.DbHello;

/// <summary>
/// <c>db-hello bootstrap --user &lt;db-user&gt; --client-id &lt;guid&gt;</c> — everything
/// an empty database needs before the page can render, in one command:
///
///   1. the schema, from the committed EF Core migrations,
///   2. the access: a contained user for a tenant's managed identity, with
///      db_datareader and db_datawriter.
///
/// Step 1 is code-first and needs no explanation. Step 2 is here because it
/// has nowhere better to be: mapping an Entra principal to a database
/// principal is neither schema (EF has no concept of it) nor an ARM resource
/// (no provider expresses it), and only the server's Entra administrator may
/// do it. Putting it next to the model at least means one language, one
/// connection, and one place to read.
///
/// Run by .github/workflows/bootstrap-sql.yml as the deploy service principal.
/// The pod runs the same image and cannot do any of this: its identity holds
/// db_datareader and db_datawriter, so the *database* refuses both steps. That
/// is the boundary, not the absence of the code.
/// </summary>
internal static class Bootstrap
{
    private const string Usage =
        "usage: db-hello bootstrap --user <database-user> --client-id <managed-identity-client-id>";

    /// <summary>
    /// The user, and the two roles that are the whole of its authorization: it
    /// may read and write rows, and it may not change the schema, grant
    /// anything, or see another database.
    ///
    /// <c>WITH SID</c> rather than <c>FROM EXTERNAL PROVIDER</c>: the latter
    /// makes the SQL server look the principal up in Microsoft Entra ID, which
    /// requires Directory Readers (or User/GroupMember/Application.Read.All on
    /// Graph) on the server's own identity. Supplying the SID skips the lookup,
    /// and a managed identity's SID is its client ID in binary — which is
    /// exactly what casting the GUID produces.
    /// </summary>
    private const string Grant = """
        SET NOCOUNT ON;

        DECLARE @name sysname = @userName;
        DECLARE @sid varbinary(16) = CAST(CAST(@clientId AS uniqueidentifier) AS varbinary(16));
        DECLARE @sql nvarchar(max);

        IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @name)
        BEGIN
            SET @sql = N'CREATE USER ' + QUOTENAME(@name)
                     + N' WITH SID = ' + CONVERT(nvarchar(100), @sid, 1)
                     + N', TYPE = E;';
            EXEC sp_executesql @sql;
        END

        -- ISNULL, because IS_ROLEMEMBER answers NULL for a principal it cannot
        -- see: treating that as "not a member" makes the ALTER ROLE below fail
        -- loudly rather than skipping the grant in silence.
        IF ISNULL(IS_ROLEMEMBER('db_datareader', @name), 0) = 0
        BEGIN
            SET @sql = N'ALTER ROLE db_datareader ADD MEMBER ' + QUOTENAME(@name) + N';';
            EXEC sp_executesql @sql;
        END

        IF ISNULL(IS_ROLEMEMBER('db_datawriter', @name), 0) = 0
        BEGIN
            SET @sql = N'ALTER ROLE db_datawriter ADD MEMBER ' + QUOTENAME(@name) + N';';
            EXEC sp_executesql @sql;
        END
        """;

    public static async Task<int> RunAsync(string[] args, CancellationToken ct)
    {
        if (Argument(args, "--user") is not { } user || Argument(args, "--client-id") is not { } clientId)
        {
            Console.Error.WriteLine(Usage);
            return 2;
        }

        // A client ID that is not a GUID would fail deep inside the CAST as a
        // conversion error naming neither the value nor the flag it came from.
        if (!Guid.TryParse(clientId, out _))
        {
            Console.Error.WriteLine($"--client-id must be a GUID, got '{clientId}'");
            return 2;
        }

        // The same factory `dotnet ef` uses, so there is one definition of how
        // to build a context outside the web application — and the connection
        // is authenticated by the same interceptor, from whatever Azure login
        // the caller has.
        await using var db = new VisitsContextFactory().CreateDbContext([]);

        Console.WriteLine($"database   {db.Database.GetDbConnection().DataSource} / {db.Database.GetDbConnection().Database}");

        var pending = (await db.Database.GetPendingMigrationsAsync(ct)).ToList();
        Console.WriteLine(pending.Count == 0
            ? "schema     up to date"
            : $"schema     applying {string.Join(", ", pending)}");

        await db.Database.MigrateAsync(ct);

        await db.Database.ExecuteSqlRawAsync(
            Grant,
            [new SqlParameter("@userName", user), new SqlParameter("@clientId", clientId)],
            ct);

        // Read back rather than assume: a user created against the wrong client
        // ID authenticates as nobody and is otherwise invisible, so the SID is
        // printed. Aliased "Value" because that is the column name SqlQuery
        // expects for a scalar result.
        var principal = await db.Database
            .SqlQuery<string>($"""
                SELECT CONCAT(p.name, N'  ', p.type_desc,
                              N'  sid ', CONVERT(nvarchar(100), p.sid, 1),
                              N'  roles ', ISNULL((SELECT STRING_AGG(r.name, N', ')
                                                   FROM sys.database_role_members AS m
                                                        INNER JOIN sys.database_principals AS r
                                                            ON r.principal_id = m.role_principal_id
                                                   WHERE m.member_principal_id = p.principal_id), N'(none)')) AS Value
                FROM sys.database_principals AS p
                WHERE p.name = {user}
                """)
            .FirstOrDefaultAsync(ct);

        if (principal is null)
        {
            Console.Error.WriteLine($"{user} was not created; nothing to hand the application");
            return 1;
        }

        Console.WriteLine($"user       {principal}");
        Console.WriteLine($"migrations {string.Join(", ", await db.Database.GetAppliedMigrationsAsync(ct))}");

        return 0;
    }

    private static string? Argument(string[] args, string name)
    {
        var at = Array.IndexOf(args, name);

        return at >= 0 && at + 1 < args.Length ? args[at + 1] : null;
    }
}
