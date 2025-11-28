FROM mcr.microsoft.com/dotnet/aspnet:9.0-alpine AS base
WORKDIR /app
EXPOSE 8080
EXPOSE 8081

RUN apk add --no-cache icu-libs

ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false

FROM mcr.microsoft.com/dotnet/sdk:9.0-alpine AS build
ARG BUILD_CONFIGURATION=Release
WORKDIR /src

COPY ["Gallery/Gallery.fsproj", "Gallery/"]
RUN dotnet restore "Gallery/Gallery.fsproj" --runtime linux-musl-x64

COPY . .
WORKDIR "/src/Gallery"

RUN dotnet build "./Gallery.fsproj" -c $BUILD_CONFIGURATION -o /app/build --no-restore

FROM build AS publish
ARG BUILD_CONFIGURATION=Release

RUN dotnet publish "./Gallery.fsproj" -c $BUILD_CONFIGURATION -o /app/publish \
    --runtime linux-musl-x64 \
    --self-contained false \
    /p:UseAppHost=false \
    /p:ReadyToRun=true \
    /p:PublishReadyToRunShowWarnings=false

FROM base AS final
WORKDIR /app

RUN addgroup -g 1000 appgroup && \
    adduser -u 1000 -G appgroup -D appuser

COPY --from=publish /app/publish .

RUN chown -R appuser:appgroup /app
USER appuser

ENV ASPNETCORE_ENVIRONMENT=Production
ENV DOTNET_EnableDiagnostics=0

ENTRYPOINT ["dotnet", "Gallery.dll"]
