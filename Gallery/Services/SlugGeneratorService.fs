namespace Gallery.Services

open System
open System.Security.Cryptography

type SlugGeneratorService() =

    let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    let charsLength = chars.Length

    member _.GenerateSlug(?length: int) =
        let len = defaultArg length 8
        let bytes = Array.zeroCreate<byte> len
        use rng = RandomNumberGenerator.Create()
        rng.GetBytes(bytes)

        String(Array.init len (fun i -> chars.[int bytes.[i] % charsLength]))

    member this.GenerateUniqueSlug(existsFunc: string -> bool, ?length: int) =
        let mutable slug = this.GenerateSlug(?length = length)
        let mutable attempts = 0
        let maxAttempts = 100

        while existsFunc(slug) && attempts < maxAttempts do
            slug <- this.GenerateSlug(?length = length)
            attempts <- attempts + 1

        if attempts >= maxAttempts then
            slug <- sprintf "%s%d" slug (DateTimeOffset.UtcNow.ToUnixTimeSeconds())

        slug
