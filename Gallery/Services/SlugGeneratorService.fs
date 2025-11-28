namespace Gallery.Services

open System
open System.Security.Cryptography

type SlugGeneratorService() =

    // Characters to use in slug (alphanumeric, case-insensitive friendly)
    let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    let charsLength = chars.Length

    // Generate a random slug of specified length (default 8 characters)
    member _.GenerateSlug(?length: int) =
        let len = defaultArg length 8
        let bytes = Array.zeroCreate<byte> len
        use rng = RandomNumberGenerator.Create()
        rng.GetBytes(bytes)

        String(Array.init len (fun i -> chars.[int bytes.[i] % charsLength]))

    // Generate a unique slug by checking if it already exists
    member this.GenerateUniqueSlug(existsFunc: string -> bool, ?length: int) =
        let mutable slug = this.GenerateSlug(?length = length)
        let mutable attempts = 0
        let maxAttempts = 100

        while existsFunc(slug) && attempts < maxAttempts do
            slug <- this.GenerateSlug(?length = length)
            attempts <- attempts + 1

        if attempts >= maxAttempts then
            // If we somehow can't generate a unique slug, append timestamp
            slug <- sprintf "%s%d" slug (DateTimeOffset.UtcNow.ToUnixTimeSeconds())

        slug
