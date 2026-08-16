"""Give a tenant's managed identity a user in the Azure SQL database.

Run by .github/workflows/bootstrap-sql.yml, which resolves every input from
Terraform state and hands them over as environment variables:

    SQL_SERVER         sql-onek8s-prototype-ab12.database.windows.net
    SQL_DATABASE       appdb
    DB_USER            id-tenant-team-alpha-prototype  (the identity's name)
    CLIENT_ID          the identity's client ID, which is also its SQL SID
    SQL_ACCESS_TOKEN   an Entra token for https://database.windows.net/,
                       belonging to the server's Entra administrator

Everything here is guarded, so re-running it is a no-op that still reports what
it found. It is the only place in the repository that speaks T-SQL, and it
exists because creating a database user has no ARM representation: it is a
data-plane act against the database itself.

The user is created `WITH SID = 0x..., TYPE = E` rather than `FROM EXTERNAL
PROVIDER`, so the SQL server never looks the principal up in Microsoft Entra ID
and therefore needs no Directory Readers role (nor the equivalent Graph
application permissions) on its own identity. A managed identity's SID is its
client ID in binary, which is what CAST(... AS uniqueidentifier) produces.
"""

import os
import struct
import sys
import time

import pyodbc

# ODBC's "use this access token instead of a password" connection attribute.
SQL_COPT_SS_ACCESS_TOKEN = 1256

# Errors that mean "ask again shortly", not "no". 40613 is what a serverless
# database answers while it wakes up from auto-pause, which on the free offer
# is the normal state of a database nobody visited for an hour.
TRANSIENT = {40613, 40197, 40501, 49918, 49919, 49920, 4060, 10928, 10929}

# One page view's worth of schema. The application only ever inserts and reads
# rows; it holds no DDL rights, so this table is created here or not at all.
SCHEMA = """
SET NOCOUNT ON;

IF OBJECT_ID('dbo.visits', 'U') IS NULL
    CREATE TABLE dbo.visits (
        id         BIGINT        IDENTITY(1, 1) NOT NULL CONSTRAINT PK_visits PRIMARY KEY,
        visited_at DATETIME2(0)  NOT NULL CONSTRAINT DF_visits_visited_at DEFAULT SYSUTCDATETIME(),
        pod        NVARCHAR(128) NOT NULL,
        cloud      NVARCHAR(32)  NOT NULL
    );
"""

# The user, and the two roles that are the whole of its authorization: it may
# read and write rows, and it may not change the schema, grant anything, or see
# another database.
GRANT = """
SET NOCOUNT ON;

DECLARE @name sysname = ?;
DECLARE @sid varbinary(16) = CAST(CAST(? AS uniqueidentifier) AS varbinary(16));
DECLARE @sql nvarchar(max);

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @name)
BEGIN
    SET @sql = N'CREATE USER ' + QUOTENAME(@name)
             + N' WITH SID = ' + CONVERT(nvarchar(100), @sid, 1)
             + N', TYPE = E;';
    EXEC sp_executesql @sql;
END

-- ISNULL, because IS_ROLEMEMBER answers NULL for a principal it cannot see:
-- treating that as "not a member" makes the ALTER ROLE below fail loudly
-- rather than skipping the grant in silence.
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
"""

# What the run actually leaves behind, read back from the database rather than
# assumed — the SID is printed because a user created against the wrong client
# ID authenticates as nobody and is otherwise invisible.
VERIFY = """
SELECT p.name,
       p.type_desc,
       CONVERT(nvarchar(100), p.sid, 1),
       ISNULL((SELECT STRING_AGG(r.name, ', ')
               FROM sys.database_role_members AS m
                    INNER JOIN sys.database_principals AS r
                        ON r.principal_id = m.role_principal_id
               WHERE m.member_principal_id = p.principal_id), '(none)')
FROM sys.database_principals AS p
WHERE p.name = ?;
"""


def value(name: str) -> str:
    got = os.environ.get(name, "")

    if not got:
        sys.exit(f"{name} is not set; this script is run by bootstrap-sql.yml")

    return got


def connect(server: str, database: str, token: str) -> pyodbc.Connection:
    """Open a connection with an Entra token instead of a password.

    ODBC wants the token as UTF-16LE bytes behind a 32-bit length, which is the
    same shape every language's driver asks for and the reason this is four
    lines rather than one.
    """
    packed = token.encode("utf-16-le")
    packed = struct.pack("<i", len(packed)) + packed

    connection_string = (
        "Driver={ODBC Driver 18 for SQL Server};"
        f"Server=tcp:{server},1433;"
        f"Database={database};"
        "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=60"
    )

    # Up to five minutes: a paused free-offer database is woken by this very
    # connection, and the first attempt is usually the one that fails.
    for attempt in range(1, 11):
        try:
            return pyodbc.connect(connection_string, attrs_before={SQL_COPT_SS_ACCESS_TOKEN: packed})
        except pyodbc.Error as error:
            code = error.args[0] if error.args else ""
            transient = any(str(number) in str(error) for number in TRANSIENT) or code in ("08001", "HYT00")

            if not transient or attempt == 10:
                raise

            print(f"database not ready yet (attempt {attempt}); waiting for the resume", flush=True)
            time.sleep(30)

    raise RuntimeError("unreachable")


def main() -> None:
    server = value("SQL_SERVER")
    database = value("SQL_DATABASE")
    user = value("DB_USER")
    client_id = value("CLIENT_ID")

    with connect(server, database, value("SQL_ACCESS_TOKEN")) as connection:
        # Autocommit because most of this is DDL and there is nothing here
        # worth rolling back as a unit: every statement is individually
        # guarded and the script is safe to run again.
        connection.autocommit = True
        cursor = connection.cursor()

        cursor.execute("SELECT SUSER_SNAME(), DB_NAME();")
        admin, current = cursor.fetchone()
        print(f"connected to {current} on {server} as {admin}")

        cursor.execute(GRANT, user, client_id)
        cursor.execute(SCHEMA)

        cursor.execute(VERIFY, user)
        row = cursor.fetchone()

        if row is None:
            sys.exit(f"{user} was not created; nothing to hand the application")

        name, kind, sid, roles = row
        print(f"user      {name} ({kind})")
        print(f"sid       {sid}   <- client ID {client_id}")
        print(f"roles     {roles}")

        cursor.execute("SELECT COUNT(*) FROM dbo.visits;")
        print(f"dbo.visits exists, {cursor.fetchone()[0]} row(s)")


if __name__ == "__main__":
    main()
