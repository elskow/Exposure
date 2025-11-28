namespace Gallery

#nowarn "20"

open System
open Microsoft.AspNetCore.Builder
open Microsoft.Extensions.Configuration
open Microsoft.Extensions.DependencyInjection
open Microsoft.Extensions.Hosting
open Microsoft.Extensions.Logging
open Microsoft.AspNetCore.Authentication.Cookies
open Microsoft.AspNetCore.Http
open Microsoft.EntityFrameworkCore
open Gallery.Data
open Gallery.Services
open Gallery.Middleware
open Microsoft.AspNetCore.Authentication.OpenIdConnect
open Microsoft.IdentityModel.Protocols.OpenIdConnect

module Program =
    let exitCode = 0

    [<EntryPoint>]
    let main args =
        let builder = WebApplication.CreateBuilder(args)

        builder
            .Services
            .AddControllersWithViews()
            .AddRazorRuntimeCompilation()

        builder.Services.AddRazorPages()

        let connectionString = builder.Configuration.GetConnectionString("DefaultConnection")
        builder.Services.AddDbContext<GalleryDbContext>(fun options ->
            options.UseSqlite(connectionString) |> ignore
        ) |> ignore

        builder.Services.AddScoped<SlugGeneratorService>() |> ignore
        builder.Services.AddScoped<ImageProcessingService>() |> ignore
        builder.Services.AddScoped<PlaceService>() |> ignore
        builder.Services.AddScoped<PhotoService>() |> ignore
        builder.Services.AddScoped<AuthenticationService>() |> ignore
        builder.Services.AddScoped<PathValidationService>() |> ignore
        builder.Services.AddScoped<FileValidationService>() |> ignore
        builder.Services.AddScoped<MalwareScanningService>() |> ignore
        builder.Services.AddScoped<InputValidationService>() |> ignore

        let authMode = builder.Configuration.["Authentication:Mode"]

        if authMode = "OIDC" then
            builder.Services.AddAuthentication(fun options ->
                options.DefaultScheme <- CookieAuthenticationDefaults.AuthenticationScheme
                options.DefaultChallengeScheme <- OpenIdConnectDefaults.AuthenticationScheme
            )
                .AddCookie(fun options ->
                    options.LoginPath <- "/admin/login"
                    options.LogoutPath <- "/admin/logout"
                    options.AccessDeniedPath <- "/admin/login"
                    options.Cookie.HttpOnly <- true
                    options.Cookie.SecurePolicy <- CookieSecurePolicy.Always
                    options.Cookie.SameSite <- SameSiteMode.Strict
                )
                .AddOpenIdConnect(OpenIdConnectDefaults.AuthenticationScheme, fun options ->
                    options.Authority <- builder.Configuration.["Authentication:OIDC:Authority"]
                    options.ClientId <- builder.Configuration.["Authentication:OIDC:ClientId"]
                    options.ClientSecret <- builder.Configuration.["Authentication:OIDC:ClientSecret"]
                    options.ResponseType <- OpenIdConnectResponseType.Code
                    options.SaveTokens <- true
                    options.GetClaimsFromUserInfoEndpoint <- true

                    let scopes = builder.Configuration.["Authentication:OIDC:Scopes"]
                    if not (String.IsNullOrEmpty(scopes)) then
                        scopes.Split(' ') |> Array.iter (fun scope -> options.Scope.Add(scope))
                ) |> ignore
        else
            builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
                .AddCookie(fun options ->
                    options.LoginPath <- "/admin/login"
                    options.LogoutPath <- "/admin/logout"
                    options.AccessDeniedPath <- "/admin/login"
                    options.Cookie.HttpOnly <- true
                    options.Cookie.SecurePolicy <- CookieSecurePolicy.Always
                    options.Cookie.SameSite <- SameSiteMode.Strict
                ) |> ignore

        builder.Services.AddAuthorization()

        let app = builder.Build()

        task {
            use scope = app.Services.CreateScope()
            let logger = scope.ServiceProvider.GetRequiredService<ILoggerFactory>().CreateLogger("Gallery.Startup")
            let dbContext = scope.ServiceProvider.GetRequiredService<GalleryDbContext>()
            dbContext.Database.EnsureCreated() |> ignore

            let placeService = scope.ServiceProvider.GetRequiredService<PlaceService>()
            do! SeedData.seedPlaces placeService logger

            let authMode = builder.Configuration.["Authentication:Mode"]
            if authMode <> "OIDC" then
                let authService = scope.ServiceProvider.GetRequiredService<AuthenticationService>()

                let defaultUsername = builder.Configuration.["Authentication:Local:Username"]
                let defaultPassword = builder.Configuration.["Authentication:Local:Password"]

                if String.IsNullOrEmpty(defaultUsername) || String.IsNullOrEmpty(defaultPassword) then
                    logger.LogWarning("No default admin credentials configured in appsettings.json")
                else
                    let! existingAdmin = authService.GetAdminUserAsync(defaultUsername)
                    match existingAdmin with
                    | None ->
                        let! result = authService.CreateAdminUserAsync(defaultUsername, defaultPassword)
                        match result with
                        | Ok _ ->
                            logger.LogInformation("Default admin user '{Username}' created from appsettings.json", defaultUsername)
                            logger.LogWarning("Change the default password immediately!")
                        | Error msg -> logger.LogError("Failed to create admin user: {Message}", msg)
                    | Some _ -> ()
        } |> fun t -> t.Wait()

        if not (builder.Environment.IsDevelopment()) then
            app.UseExceptionHandler("/Home/Error")
            app.UseHsts() |> ignore

        app.UseStatusCodePagesWithReExecute("/404") |> ignore

        app.UseHttpsRedirection()

        app.UseSecurityHeaders() |> ignore

        app.UseStaticFiles()
        app.UseRouting()
        app.UseAuthentication()
        app.UseAuthorization()

        app.MapControllerRoute(name = "default", pattern = "{controller=Home}/{action=Index}/{id?}")
        app.MapControllerRoute(name = "admin", pattern = "admin/{action=Index}/{id?}", defaults = {| controller = "Admin" |})

        app.MapRazorPages()

        app.Run()

        exitCode
