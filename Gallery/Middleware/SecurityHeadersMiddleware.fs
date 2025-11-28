namespace Gallery.Middleware

open System
open System.Threading.Tasks
open Microsoft.AspNetCore.Http

type SecurityHeadersMiddleware(next: RequestDelegate) =

    member _.InvokeAsync(context: HttpContext) : Task =
        let headers = context.Response.Headers

        // Prevent clickjacking - page cannot be embedded in iframes
        headers.["X-Frame-Options"] <- "DENY"

        // Prevent MIME type sniffing
        headers.["X-Content-Type-Options"] <- "nosniff"

        // Enable XSS filter in browsers (legacy, but still useful for older browsers)
        headers.["X-XSS-Protection"] <- "1; mode=block"

        // Control referrer information
        headers.["Referrer-Policy"] <- "strict-origin-when-cross-origin"

        // Permissions Policy - restrict browser features
        headers.["Permissions-Policy"] <- "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()"

        // Content Security Policy
        // - default-src 'self': Only allow resources from same origin by default
        // - script-src 'self' 'unsafe-inline': Allow scripts from same origin and inline scripts (needed for Razor)
        // - style-src 'self' 'unsafe-inline': Allow styles from same origin and inline styles
        // - img-src 'self' data: blob:: Allow images from same origin, data URIs, and blob URIs
        // - font-src 'self': Allow fonts from same origin only
        // - connect-src 'self': Allow AJAX/fetch to same origin only
        // - frame-ancestors 'none': Prevent embedding in frames (similar to X-Frame-Options)
        // - form-action 'self': Forms can only submit to same origin
        // - base-uri 'self': Restrict base tag to same origin
        // - object-src 'none': Disallow plugins like Flash
        let csp = String.concat "; " [
            "default-src 'self'"
            "script-src 'self' 'unsafe-inline'"
            "style-src 'self' 'unsafe-inline'"
            "img-src 'self' data: blob:"
            "font-src 'self'"
            "connect-src 'self'"
            "frame-ancestors 'none'"
            "form-action 'self'"
            "base-uri 'self'"
            "object-src 'none'"
        ]
        headers.["Content-Security-Policy"] <- csp

        // Strict Transport Security (HSTS)
        // Only add for HTTPS requests to avoid issues during development
        if context.Request.IsHttps then
            // max-age=31536000 = 1 year
            // includeSubDomains - apply to all subdomains
            headers.["Strict-Transport-Security"] <- "max-age=31536000; includeSubDomains"

        // Cross-Origin policies for additional isolation
        headers.["Cross-Origin-Opener-Policy"] <- "same-origin"
        headers.["Cross-Origin-Resource-Policy"] <- "same-origin"

        next.Invoke(context)


// Extension method for easy middleware registration
[<AutoOpen>]
module SecurityHeadersMiddlewareExtensions =
    open Microsoft.AspNetCore.Builder

    type IApplicationBuilder with
        member this.UseSecurityHeaders() =
            this.UseMiddleware<SecurityHeadersMiddleware>()
