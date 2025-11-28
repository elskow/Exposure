namespace Gallery

#nowarn "20"

open System
open System.Collections.Generic
open System.IO
open System.Linq
open System.Threading.Tasks
open Microsoft.AspNetCore
open Microsoft.AspNetCore.Builder
open Microsoft.AspNetCore.Hosting
open Microsoft.AspNetCore.HttpsPolicy
open Microsoft.Extensions.Configuration
open Microsoft.Extensions.DependencyInjection
open Microsoft.Extensions.Hosting
open Microsoft.Extensions.Logging
open Microsoft.AspNetCore.Authentication.Cookies
open Microsoft.AspNetCore.Http
open Microsoft.EntityFrameworkCore
open Gallery.Data
open Gallery.Services
open System.Threading.Tasks
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

        // Add SQLite Database
        let connectionString = builder.Configuration.GetConnectionString("DefaultConnection")
        builder.Services.AddDbContext<GalleryDbContext>(fun options ->
            options.UseSqlite(connectionString) |> ignore
        ) |> ignore

        // Register services
        builder.Services.AddScoped<SlugGeneratorService>() |> ignore
        builder.Services.AddScoped<ImageProcessingService>() |> ignore
        builder.Services.AddScoped<PlaceService>() |> ignore
        builder.Services.AddScoped<PhotoService>() |> ignore
        builder.Services.AddScoped<AuthenticationService>() |> ignore
        builder.Services.AddScoped<PathValidationService>() |> ignore
        builder.Services.AddScoped<FileValidationService>() |> ignore
        builder.Services.AddScoped<MalwareScanningService>() |> ignore

        // Add Authentication services based on configuration
        let authMode = builder.Configuration.["Authentication:Mode"]

        if authMode = "OIDC" then
            // Configure OIDC authentication
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
            // Default to local authentication with cookies
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

        // Ensure database is created and seed data
        task {
            use scope = app.Services.CreateScope()
            let dbContext = scope.ServiceProvider.GetRequiredService<GalleryDbContext>()
            dbContext.Database.EnsureCreated() |> ignore

            // Seed sample data if database is empty
            let placeService = scope.ServiceProvider.GetRequiredService<PlaceService>()
            do! SeedData.seedPlaces placeService

            // Create default admin user if using local auth and none exists
            let authMode = builder.Configuration.["Authentication:Mode"]
            if authMode <> "OIDC" then
                let authService = scope.ServiceProvider.GetRequiredService<AuthenticationService>()

                // Read initial admin credentials from configuration
                let defaultUsername = builder.Configuration.["Authentication:Local:Username"]
                let defaultPassword = builder.Configuration.["Authentication:Local:Password"]

                if String.IsNullOrEmpty(defaultUsername) || String.IsNullOrEmpty(defaultPassword) then
                    printfn "Warning: No default admin credentials configured in appsettings.json"
                else
                    let! existingAdmin = authService.GetAdminUserAsync(defaultUsername)
                    match existingAdmin with
                    | None ->
                        // Create default admin user from configuration
                        let! result = authService.CreateAdminUserAsync(defaultUsername, defaultPassword)
                        match result with
                        | Ok _ ->
                            printfn "Default admin user '%s' created from appsettings.json" defaultUsername
                            printfn "⚠️  WARNING: Change the default password immediately!"
                        | Error msg -> printfn "Failed to create admin user: %s" msg
                    | Some _ -> ()
        } |> fun t -> t.Wait()

        if not (builder.Environment.IsDevelopment()) then
            app.UseExceptionHandler("/Home/Error")
            app.UseHsts
                () |> ignore

        // Handle 404 errors with custom page
        app.UseStatusCodePagesWithReExecute("/404") |> ignore

        app.UseHttpsRedirection()

        app.UseStaticFiles()
        app.UseRouting()
        app.UseAuthentication()
        app.UseAuthorization()

        app.MapControllerRoute(name = "default", pattern = "{controller=Home}/{action=Index}/{id?}")
        app.MapControllerRoute(name = "admin", pattern = "admin/{action=Index}/{id?}", defaults = {| controller = "Admin" |})

        app.MapRazorPages()

        app.Run()

        exitCode
