namespace Gallery.Middleware

open System
open System.Threading.Tasks
open Microsoft.AspNetCore.Http

type SecurityHeadersMiddleware(next: RequestDelegate) =

    member _.InvokeAsync(context: HttpContext) : Task =
        let headers = context.Response.Headers

        headers.["X-Frame-Options"] <- "DENY"
        headers.["X-Content-Type-Options"] <- "nosniff"
        headers.["X-XSS-Protection"] <- "1; mode=block"
        headers.["Referrer-Policy"] <- "strict-origin-when-cross-origin"
        headers.["Permissions-Policy"] <- "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()"

        let csp = String.concat "; " [
            "default-src 'self'"
            "script-src 'self' 'unsafe-inline' blob:"
            "style-src 'self' 'unsafe-inline'"
            "img-src 'self' data: blob:"
            "font-src 'self'"
            "connect-src 'self'"
            "frame-ancestors 'none'"
            "form-action 'self'"
            "base-uri 'self'"
            "object-src 'none'"
            "worker-src 'self' blob:"
        ]
        headers.["Content-Security-Policy"] <- csp

        if context.Request.IsHttps then
            headers.["Strict-Transport-Security"] <- "max-age=31536000; includeSubDomains"

        headers.["Cross-Origin-Opener-Policy"] <- "same-origin"
        headers.["Cross-Origin-Resource-Policy"] <- "same-origin"

        next.Invoke(context)


[<AutoOpen>]
module SecurityHeadersMiddlewareExtensions =
    open Microsoft.AspNetCore.Builder

    type IApplicationBuilder with
        member this.UseSecurityHeaders() =
            this.UseMiddleware<SecurityHeadersMiddleware>()
