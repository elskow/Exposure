namespace Gallery.Services

open System
open System.Linq
open System.Security.Cryptography
open System.Threading
open Microsoft.EntityFrameworkCore
open Microsoft.Extensions.Logging
open OtpNet
open QRCoder
open Gallery.Data
open Gallery.Models

type AuthenticationService(context: GalleryDbContext, logger: ILogger<AuthenticationService>) =

    static let createUserLock = new SemaphoreSlim(1, 1)

    let genericAuthError = "Invalid credentials"

    member _.GenerateTotpSecret() =
        let key = KeyGeneration.GenerateRandomKey(20)
        Base32Encoding.ToString(key)

    member _.VerifyTotpCode(secret: string, code: string) =
        try
            let secretBytes = Base32Encoding.ToBytes(secret)
            let totp = new Totp(secretBytes)
            let mutable timeStepMatched = 0L
            totp.VerifyTotp(code, &timeStepMatched, VerificationWindow(2, 2))
        with
        | _ -> false

    member _.GenerateTotpQrCode(username: string, secret: string, issuer: string) =
        let totpUrl = sprintf "otpauth://totp/%s:%s?secret=%s&issuer=%s" issuer username secret issuer
        use qrGenerator = new QRCodeGenerator()
        use qrCodeData = qrGenerator.CreateQrCode(totpUrl, QRCodeGenerator.ECCLevel.Q)
        use qrCode = new PngByteQRCode(qrCodeData)
        qrCode.GetGraphic(20)

    member _.HashPassword(password: string) =
        use rng = RandomNumberGenerator.Create()
        let salt = Array.zeroCreate<byte> 16
        rng.GetBytes(salt)

        use pbkdf2 = new Rfc2898DeriveBytes(password, salt, 10000, HashAlgorithmName.SHA256)
        let hash = pbkdf2.GetBytes(32)

        let hashBytes = Array.append salt hash
        Convert.ToBase64String(hashBytes)

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

    member this.GetAdminUserAsync(username: string) =
        task {
            let! user = context.AdminUsers.FirstOrDefaultAsync(fun u -> u.Username = username)
            return if isNull user then None else Some(user)
        }

    member this.CreateAdminUserAsync(username: string, password: string) =
        task {
            let! _ = createUserLock.WaitAsync()

            try
                let! existingUser = this.GetAdminUserAsync(username)

                match existingUser with
                | Some _ ->
                    logger.LogWarning("Attempted to create duplicate admin user: {Username}", username)
                    return Error "User already exists"
                | None ->
                    let user = AdminUser()
                    user.Username <- username
                    user.PasswordHash <- this.HashPassword(password)
                    user.TotpEnabled <- false
                    user.CreatedAt <- DateTime.UtcNow

                    context.AdminUsers.Add(user) |> ignore
                    let! _ = context.SaveChangesAsync()
                    logger.LogInformation("Created admin user: {Username}", username)
                    return Ok user.Id
            finally
                createUserLock.Release() |> ignore
        }

    member this.EnableTotpAsync(username: string) =
        task {
            let! userOpt = this.GetAdminUserAsync(username)

            match userOpt with
            | None ->
                logger.LogWarning("Attempted to enable TOTP for non-existent user: {Username}", username)
                return Error "User not found"
            | Some user ->
                if user.TotpEnabled && not (String.IsNullOrEmpty(user.TotpSecret)) then
                    return Error "TOTP already enabled"
                else
                    let secret = this.GenerateTotpSecret()
                    user.TotpSecret <- secret
                    user.TotpEnabled <- true

                    let! _ = context.SaveChangesAsync()
                    logger.LogInformation("TOTP enabled for user: {Username}", username)
                    return Ok secret
        }

    member this.DisableTotpAsync(username: string) =
        task {
            let! userOpt = this.GetAdminUserAsync(username)

            match userOpt with
            | None ->
                logger.LogWarning("Attempted to disable TOTP for non-existent user: {Username}", username)
                return false
            | Some user ->
                user.TotpSecret <- null
                user.TotpEnabled <- false

                let! _ = context.SaveChangesAsync()
                logger.LogInformation("TOTP disabled for user: {Username}", username)
                return true
        }

    member this.AuthenticateAsync(username: string, password: string, totpCode: string option) =
        task {
            let! userOpt = this.GetAdminUserAsync(username)

            match userOpt with
            | None ->
                let _ = this.VerifyPassword(password, this.HashPassword("dummy"))
                logger.LogWarning("Authentication failed: user not found - {Username}", username)
                return Error genericAuthError

            | Some user ->
                if not (this.VerifyPassword(password, user.PasswordHash)) then
                    logger.LogWarning("Authentication failed: invalid password for user - {Username}", username)
                    return Error genericAuthError
                else
                    if user.TotpEnabled then
                        match totpCode with
                        | None ->
                            logger.LogWarning("Authentication failed: TOTP required but not provided for user - {Username}", username)
                            return Error genericAuthError
                        | Some code ->
                            if not (String.IsNullOrEmpty(user.TotpSecret)) && this.VerifyTotpCode(user.TotpSecret, code) then
                                user.LastLoginAt <- DateTime.UtcNow
                                let! _ = context.SaveChangesAsync()
                                logger.LogInformation("Authentication successful for user: {Username}", username)
                                return Ok user
                            else
                                logger.LogWarning("Authentication failed: invalid TOTP code for user - {Username}", username)
                                return Error genericAuthError
                    else
                        user.LastLoginAt <- DateTime.UtcNow
                        let! _ = context.SaveChangesAsync()
                        logger.LogInformation("Authentication successful for user: {Username}", username)
                        return Ok user
        }
