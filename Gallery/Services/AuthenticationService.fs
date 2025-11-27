namespace Gallery.Services

open System
open System.Linq
open System.Security.Cryptography
open Microsoft.EntityFrameworkCore
open OtpNet
open QRCoder
open Gallery.Data
open Gallery.Models

type AuthenticationService(context: GalleryDbContext) =

    // Generate a random TOTP secret
    member _.GenerateTotpSecret() =
        let key = KeyGeneration.GenerateRandomKey(20)
        Base32Encoding.ToString(key)

    // Verify TOTP code
    member _.VerifyTotpCode(secret: string, code: string) =
        try
            let secretBytes = Base32Encoding.ToBytes(secret)
            let totp = new Totp(secretBytes)
            let mutable timeStepMatched = 0L
            totp.VerifyTotp(code, &timeStepMatched, VerificationWindow(2, 2))
        with
        | _ -> false

    // Generate QR code for Google Authenticator
    member _.GenerateTotpQrCode(username: string, secret: string, issuer: string) =
        let totpUrl = sprintf "otpauth://totp/%s:%s?secret=%s&issuer=%s" issuer username secret issuer
        use qrGenerator = new QRCodeGenerator()
        use qrCodeData = qrGenerator.CreateQrCode(totpUrl, QRCodeGenerator.ECCLevel.Q)
        use qrCode = new PngByteQRCode(qrCodeData)
        qrCode.GetGraphic(20)

    // Hash password using BCrypt-like algorithm (simple PBKDF2 for now)
    member _.HashPassword(password: string) =
        use rng = RandomNumberGenerator.Create()
        let salt = Array.zeroCreate<byte> 16
        rng.GetBytes(salt)

        use pbkdf2 = new Rfc2898DeriveBytes(password, salt, 10000, HashAlgorithmName.SHA256)
        let hash = pbkdf2.GetBytes(32)

        let hashBytes = Array.append salt hash
        Convert.ToBase64String(hashBytes)

    // Verify password
    member _.VerifyPassword(password: string, hashedPassword: string) =
        try
            let hashBytes = Convert.FromBase64String(hashedPassword)
            let salt = hashBytes.[0..15]
            let hash = hashBytes.[16..]

            use pbkdf2 = new Rfc2898DeriveBytes(password, salt, 10000, HashAlgorithmName.SHA256)
            let testHash = pbkdf2.GetBytes(32)

            hash.SequenceEqual(testHash)
        with
        | _ -> false

    // Get admin user by username
    member this.GetAdminUserAsync(username: string) =
        task {
            let! user = context.AdminUsers.FirstOrDefaultAsync(fun u -> u.Username = username)
            return if isNull user then None else Some(user)
        }

    // Create admin user
    member this.CreateAdminUserAsync(username: string, password: string) =
        task {
            let! existingUser = this.GetAdminUserAsync(username)

            match existingUser with
            | Some _ -> return Error "User already exists"
            | None ->
                let user = AdminUser()
                user.Username <- username
                user.PasswordHash <- this.HashPassword(password)
                user.TotpEnabled <- false
                user.CreatedAt <- DateTime.UtcNow

                context.AdminUsers.Add(user) |> ignore
                let! _ = context.SaveChangesAsync()
                return Ok user.Id
        }

    // Enable TOTP for user
    member this.EnableTotpAsync(username: string) =
        task {
            let! userOpt = this.GetAdminUserAsync(username)

            match userOpt with
            | None -> return Error "User not found"
            | Some user ->
                if user.TotpEnabled && not (String.IsNullOrEmpty(user.TotpSecret)) then
                    return Error "TOTP already enabled"
                else
                    let secret = this.GenerateTotpSecret()
                    user.TotpSecret <- secret
                    user.TotpEnabled <- true

                    let! _ = context.SaveChangesAsync()
                    return Ok secret
        }

    // Disable TOTP for user
    member this.DisableTotpAsync(username: string) =
        task {
            let! userOpt = this.GetAdminUserAsync(username)

            match userOpt with
            | None -> return false
            | Some user ->
                user.TotpSecret <- null
                user.TotpEnabled <- false

                let! _ = context.SaveChangesAsync()
                return true
        }

    // Authenticate user with password and optional TOTP
    member this.AuthenticateAsync(username: string, password: string, totpCode: string option) =
        task {
            let! userOpt = this.GetAdminUserAsync(username)

            match userOpt with
            | None -> return Error "Invalid credentials"
            | Some user ->
                // Verify password
                if not (this.VerifyPassword(password, user.PasswordHash)) then
                    return Error "Invalid credentials"
                else
                    // Check TOTP if enabled
                    if user.TotpEnabled then
                        match totpCode with
                        | None -> return Error "TOTP code required"
                        | Some code ->
                            if not (String.IsNullOrEmpty(user.TotpSecret)) && this.VerifyTotpCode(user.TotpSecret, code) then
                                user.LastLoginAt <- DateTime.UtcNow
                                let! _ = context.SaveChangesAsync()
                                return Ok user
                            else
                                return Error "Invalid TOTP code"
                    else
                        user.LastLoginAt <- DateTime.UtcNow
                        let! _ = context.SaveChangesAsync()
                        return Ok user
        }

    // Update last login time
    member this.UpdateLastLoginAsync(username: string) =
        task {
            let! userOpt = this.GetAdminUserAsync(username)

            match userOpt with
            | None -> return ()
            | Some user ->
                user.LastLoginAt <- DateTime.UtcNow
                let! _ = context.SaveChangesAsync()
                return ()
        }
