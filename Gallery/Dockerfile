FROM mcr.microsoft.com/dotnet/aspnet:9.0-alpine AS base
WORKDIR /app
EXPOSE 8080

RUN apk add --no-cache icu-libs su-exec

ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false

# Build CSS and minify JS with Node
FROM node:22-alpine AS assets-build
WORKDIR /src/Gallery
COPY Gallery/package*.json ./
RUN npm ci
COPY Gallery/tailwind.config.js Gallery/postcss.config.mjs ./
COPY Gallery/wwwroot/css/site.css ./wwwroot/css/
COPY Gallery/wwwroot/js/site.js ./wwwroot/js/
COPY Gallery/Views ./Views/
RUN npm run build-css && npm run minify-js

FROM mcr.microsoft.com/dotnet/sdk:9.0-alpine AS publish
ARG BUILD_CONFIGURATION=Release
WORKDIR /src

# Copy and restore first (cached layer)
COPY ["Gallery/Gallery.fsproj", "Gallery/"]
RUN dotnet restore "Gallery/Gallery.fsproj"

# Copy source and build
COPY . .
WORKDIR "/src/Gallery"

# Copy compiled CSS and minified JS from assets-build stage
COPY --from=assets-build /src/Gallery/wwwroot/css/site.compiled.css ./wwwroot/css/
COPY --from=assets-build /src/Gallery/wwwroot/js/site.min.js ./wwwroot/js/

RUN dotnet publish "./Gallery.fsproj" -c $BUILD_CONFIGURATION -o /app/publish \
    --no-restore

FROM base AS final
WORKDIR /app

# Create user and directories with proper permissions
RUN addgroup -g 1000 appgroup && \
    adduser -u 1000 -G appgroup -D appuser && \
    mkdir -p /app/data /app/wwwroot/images/places && \
    chown -R appuser:appgroup /app

# Copy with ownership in one layer
COPY --from=publish --chown=appuser:appgroup /app/publish .

# Copy entrypoint script
COPY --chmod=755 Gallery/docker-entrypoint.sh /docker-entrypoint.sh

# Ensure images directory is writable
RUN chown -R appuser:appgroup /app/wwwroot/images

# Run as root initially, entrypoint will drop to appuser after fixing permissions
# USER appuser

# Production optimizations
ENV ASPNETCORE_ENVIRONMENT=Production
ENV DOTNET_EnableDiagnostics=0
ENV DOTNET_gcServer=0
ENV DOTNET_TieredPGO=1
ENV DOTNET_TC_QuickJitForLoops=1
ENV DOTNET_ReadyToRun=1

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/ || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
