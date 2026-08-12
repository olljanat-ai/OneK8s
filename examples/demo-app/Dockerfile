FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY src/ .
RUN dotnet publish -c Release -o /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app .
ENV ASPNETCORE_URLS=http://0.0.0.0:8080
# Non-root user shipped with the aspnet base image.
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "OneK8s.DemoApp.dll"]
