FROM mcr.microsoft.com/dotnet/aspnet:9.0-alpine AS base
WORKDIR /app
EXPOSE 8080

RUN apk add --no-cache icu-libs

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
RUN dotnet restore "Gallery/Gallery.fsproj" --runtime linux-musl-x64

# Copy source and build
COPY . .
WORKDIR "/src/Gallery"

# Copy compiled CSS and minified JS from assets-build stage
COPY --from=assets-build /src/Gallery/wwwroot/css/site.compiled.css ./wwwroot/css/
COPY --from=assets-build /src/Gallery/wwwroot/js/site.min.js ./wwwroot/js/

RUN dotnet publish "./Gallery.fsproj" -c $BUILD_CONFIGURATION -o /app/publish \
    --runtime linux-musl-x64 \
    --no-restore

FROM base AS final
WORKDIR /app

RUN addgroup -g 1000 appgroup && \
    adduser -u 1000 -G appgroup -D appuser

COPY --from=publish /app/publish .

RUN chown -R appuser:appgroup /app
USER appuser

ENV ASPNETCORE_ENVIRONMENT=Production
ENV DOTNET_EnableDiagnostics=0
ENV DOTNET_gcServer=0

ENTRYPOINT ["dotnet", "Gallery.dll"]
