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
        builder.Services.AddScoped<PlaceService>() |> ignore
        builder.Services.AddScoped<PhotoService>() |> ignore

        // Register DummyDataService as a singleton (keeping for backward compatibility)
        builder.Services.AddSingleton<DummyDataService>()

        // Add Authentication services
        builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
            .AddCookie(fun options ->
                options.LoginPath <- "/admin/login"
                options.LogoutPath <- "/admin/logout"
                options.AccessDeniedPath <- "/admin/login"
                options.Cookie.HttpOnly <- true
                options.Cookie.SecurePolicy <- CookieSecurePolicy.SameAsRequest
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
        } |> fun t -> t.Wait()

        if not (builder.Environment.IsDevelopment()) then
            app.UseExceptionHandler("/Home/Error")
            app.UseHsts
                () |> ignore

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
