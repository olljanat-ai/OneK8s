# Same two stages, same chiseled runtime and same non-root user as apps/hello:
# the SDK compiles, and an Ubuntu image with no shell, no package manager and
# no root user serves. This app reaches one more service than that one (Entra
# ID and Azure SQL, both over TLS on 443/1433), and needs nothing extra in the
# image to do it.
FROM mcr.microsoft.com/dotnet/sdk:10.0-noble AS build
WORKDIR /src

# The project file alone first, so the restore layer is only invalidated when a
# dependency changes rather than on every source edit.
COPY src/DbHello.csproj ./
RUN dotnet restore

COPY src/ ./
RUN dotnet publish -c Release --no-restore -o /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled AS final
WORKDIR /app
COPY --from=build /app ./

# $APP_UID resolves to 1654, the "app" user of the .NET images, which is the
# same UID the chart pins in the pod's securityContext. Change one and the
# other has to follow.
USER $APP_UID

# 8080 is the .NET default for a non-root container: binding 80 needs a
# capability this user does not have. Named "http" in the Service.
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

ENTRYPOINT ["dotnet", "db-hello.dll"]
