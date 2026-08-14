# Two stages: the SDK compiles, the chiseled ASP.NET runtime serves. "Chiseled"
# is Ubuntu with everything the app does not need removed — no shell, no
# package manager, no root user — which is both the smallest and the least
# useful thing to break into of the images Microsoft publishes.
FROM mcr.microsoft.com/dotnet/sdk:10.0-noble AS build
WORKDIR /src

# The project file alone first, so the restore layer is only invalidated when a
# dependency changes rather than on every source edit.
COPY src/Hello.csproj ./
RUN dotnet restore

COPY src/ ./
RUN dotnet publish -c Release --no-restore -o /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled AS final
WORKDIR /app
COPY --from=build /app ./

# The chiseled images ship a non-root user (UID 1654) but still default to
# root; $APP_UID is how they expect you to switch.
USER $APP_UID

# 8080 is the .NET 8+ default for a non-root container: binding 80 needs a
# capability this user does not have. Named "http" in the Service.
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

ENTRYPOINT ["dotnet", "hello.dll"]
