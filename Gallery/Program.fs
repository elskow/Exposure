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
open Gallery.Services

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
        
        // Register DummyDataService as a singleton
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