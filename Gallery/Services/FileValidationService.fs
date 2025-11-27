namespace Gallery.Services

open System
open System.IO
open System.Linq
open Microsoft.AspNetCore.Http
open Microsoft.Extensions.Configuration
open Microsoft.Extensions.Logging
open SixLabors.ImageSharp

type FileValidationService(configuration: IConfiguration, logger: ILogger<FileValidationService>) =

    // Configuration values
    let maxFileSizeInMB =
        let configValue = configuration.["FileUpload:MaxFileSizeInMB"]
        if String.IsNullOrEmpty(configValue) then 10 else Int32.Parse(configValue)

    let maxFilesPerUpload =
        let configValue = configuration.["FileUpload:MaxFilesPerUpload"]
        if String.IsNullOrEmpty(configValue) then 50 else Int32.Parse(configValue)

    let allowedExtensions =
        let configured = configuration.GetSection("FileUpload:AllowedExtensions").Get<string[]>()
        if isNull configured then [|".jpg"; ".jpeg"; ".png"; ".webp"|] else configured

    let allowedMimeTypes =
        let configured = configuration.GetSection("FileUpload:AllowedMimeTypes").Get<string[]>()
        if isNull configured then [|"image/jpeg"; "image/png"; "image/webp"|] else configured

    let validateMagicNumbers =
        let configValue = configuration.["FileUpload:ValidateMagicNumbers"]
        if String.IsNullOrEmpty(configValue) then true else Boolean.Parse(configValue)

    let maxImageWidth =
        let configValue = configuration.["FileUpload:MaxImageWidth"]
        if String.IsNullOrEmpty(configValue) then 10000 else Int32.Parse(configValue)

    let maxImageHeight =
        let configValue = configuration.["FileUpload:MaxImageHeight"]
        if String.IsNullOrEmpty(configValue) then 10000 else Int32.Parse(configValue)

    let maxImagePixels =
        let configValue = configuration.["FileUpload:MaxImagePixels"]
        if String.IsNullOrEmpty(configValue) then 50000000L else Int64.Parse(configValue) // 50 megapixels

    let validateImageDimensions =
        let configValue = configuration.["FileUpload:ValidateImageDimensions"]
        if String.IsNullOrEmpty(configValue) then true else Boolean.Parse(configValue)

    // Magic numbers (file signatures) for image formats
    let imageMagicNumbers = [
        // JPEG: FF D8 FF
        ([| 0xFFuy; 0xD8uy; 0xFFuy |], "JPEG")
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        ([| 0x89uy; 0x50uy; 0x4Euy; 0x47uy; 0x0Duy; 0x0Auy; 0x1Auy; 0x0Auy |], "PNG")
        // WebP: 52 49 46 46 (RIFF) ... 57 45 42 50 (WEBP)
        ([| 0x52uy; 0x49uy; 0x46uy; 0x46uy |], "WebP (RIFF)")
        // GIF: 47 49 46 38 37 61 or 47 49 46 38 39 61
        ([| 0x47uy; 0x49uy; 0x46uy; 0x38uy; 0x37uy; 0x61uy |], "GIF87a")
        ([| 0x47uy; 0x49uy; 0x46uy; 0x38uy; 0x39uy; 0x61uy |], "GIF89a")
    ]

    // Check if byte array starts with magic number
    let startsWith (buffer: byte[]) (magicNumber: byte[]) =
        if buffer.Length < magicNumber.Length then
            false
        else
            magicNumber |> Array.mapi (fun i b -> buffer.[i] = b) |> Array.forall id

    // Validate file magic number (file signature)
    member _.ValidateMagicNumber(file: IFormFile) : Result<string, string> =
        try
            use stream = file.OpenReadStream()
            let buffer = Array.zeroCreate<byte> 8
            let bytesRead = stream.Read(buffer, 0, 8)

            if bytesRead < 4 then
                Error "File is too small to validate"
            else
                let matchedFormat =
                    imageMagicNumbers
                    |> List.tryFind (fun (magic, _) -> startsWith buffer magic)

                match matchedFormat with
                | Some (_, format) -> Ok format
                | None -> Error "File content does not match any valid image format (invalid magic number)"
        with
        | ex -> Error (sprintf "Error reading file: %s" ex.Message)

    // Validate file extension
    member _.ValidateExtension(file: IFormFile) : Result<unit, string> =
        let extension = Path.GetExtension(file.FileName).ToLowerInvariant()

        if String.IsNullOrEmpty(extension) then
            Error "File has no extension"
        elif not (allowedExtensions.Contains(extension)) then
            Error (sprintf "File extension '%s' is not allowed. Allowed: %s"
                extension (String.Join(", ", allowedExtensions)))
        else
            Ok ()

    // Validate MIME type
    member _.ValidateMimeType(file: IFormFile) : Result<unit, string> =
        if String.IsNullOrEmpty(file.ContentType) then
            Error "File MIME type is missing"
        elif not (allowedMimeTypes.Contains(file.ContentType.ToLowerInvariant())) then
            Error (sprintf "MIME type '%s' is not allowed. Allowed: %s"
                file.ContentType (String.Join(", ", allowedMimeTypes)))
        else
            Ok ()

    // Validate file size
    member _.ValidateFileSize(file: IFormFile) : Result<unit, string> =
        let maxSizeBytes = int64 maxFileSizeInMB * 1024L * 1024L

        if file.Length = 0L then
            Error "File is empty"
        elif file.Length > maxSizeBytes then
            Error (sprintf "File size (%.2f MB) exceeds maximum allowed size (%d MB)"
                (float file.Length / 1024.0 / 1024.0) maxFileSizeInMB)
        else
            Ok ()

    // Validate number of files
    member _.ValidateFileCount(fileCount: int) : Result<unit, string> =
        if fileCount = 0 then
            Error "No files provided"
        elif fileCount > maxFilesPerUpload then
            Error (sprintf "Too many files (%d). Maximum allowed: %d" fileCount maxFilesPerUpload)
        else
            Ok ()

    // Validate image dimensions to prevent image bombs
    member _.ValidateImageDimensions(file: IFormFile) : Result<(int * int), string> =
        if not validateImageDimensions then
            Ok (0, 0) // Skip validation
        else
            try
                use stream = file.OpenReadStream()

                // Use ImageSharp to safely read image info without full decompression
                let imageInfo = Image.Identify(stream)

                if isNull imageInfo then
                    Error "Unable to read image information"
                else
                    let width = imageInfo.Width
                    let height = imageInfo.Height
                    let totalPixels = int64 width * int64 height

                    logger.LogDebug("Image {FileName}: {Width}x{Height} ({Pixels} pixels)",
                        file.FileName, width, height, totalPixels)

                    // Check width
                    if width > maxImageWidth then
                        Error (sprintf "Image width (%d) exceeds maximum allowed (%d)" width maxImageWidth)
                    // Check height
                    elif height > maxImageHeight then
                        Error (sprintf "Image height (%d) exceeds maximum allowed (%d)" height maxImageHeight)
                    // Check total pixels (image bomb protection)
                    elif totalPixels > maxImagePixels then
                        let megapixels = float totalPixels / 1000000.0
                        let maxMegapixels = float maxImagePixels / 1000000.0
                        Error (sprintf "Image size (%.1f MP) exceeds maximum allowed (%.1f MP). Possible decompression bomb."
                            megapixels maxMegapixels)
                    else
                        Ok (width, height)
            with
            | :? OutOfMemoryException as ex ->
                logger.LogError(ex, "Out of memory while processing image {FileName} - possible image bomb", file.FileName)
                Error "Image processing failed: out of memory (possible decompression bomb)"
            | ex ->
                logger.LogError(ex, "Error validating image dimensions for {FileName}", file.FileName)
                Error (sprintf "Error reading image: %s" ex.Message)

    // Validate file name (prevent path traversal)
    member _.ValidateFileName(file: IFormFile) : Result<unit, string> =
        let fileName = Path.GetFileName(file.FileName)

        if String.IsNullOrWhiteSpace(fileName) then
            Error "Invalid file name"
        elif fileName.Contains("..") || fileName.Contains("/") || fileName.Contains("\\") then
            Error "File name contains invalid characters (possible path traversal attempt)"
        elif fileName.Length > 255 then
            Error "File name is too long (max 255 characters)"
        else
            Ok ()

    // Comprehensive validation
    member this.ValidateFile(file: IFormFile) : Result<string, string> =
        match this.ValidateFileName(file) with
        | Error msg -> Error msg
        | Ok _ ->
            match this.ValidateFileSize(file) with
            | Error msg -> Error msg
            | Ok _ ->
                match this.ValidateExtension(file) with
                | Error msg -> Error msg
                | Ok _ ->
                    match this.ValidateMimeType(file) with
                    | Error msg -> Error msg
                    | Ok _ ->
                        // Validate magic numbers
                        let magicResult =
                            if validateMagicNumbers then
                                this.ValidateMagicNumber(file)
                            else
                                Ok "Skipped"

                        match magicResult with
                        | Error msg -> Error msg
                        | Ok format ->
                            // Validate image dimensions (image bomb protection)
                            match this.ValidateImageDimensions(file) with
                            | Error msg -> Error msg
                            | Ok (width, height) ->
                                if width > 0 && height > 0 then
                                    Ok (sprintf "%s (%dx%d)" format width height)
                                else
                                    Ok format

    // Validate multiple files
    member this.ValidateFiles(files: IFormFile list) : Result<unit, string list> =
        // Check file count
        match this.ValidateFileCount(files.Length) with
        | Error msg -> Error [msg]
        | Ok _ ->
            // Validate each file
            let validationResults =
                files
                |> List.mapi (fun i file ->
                    match this.ValidateFile(file) with
                    | Ok format -> Ok (i, file.FileName, format)
                    | Error msg -> Error (sprintf "File %d (%s): %s" (i + 1) file.FileName msg)
                )

            let errors =
                validationResults
                |> List.choose (function Error msg -> Some msg | Ok _ -> None)

            if errors.IsEmpty then
                Ok ()
            else
                Error errors

    // Get configuration info (for logging/debugging)
    member _.GetConfigurationInfo() =
        sprintf "Max File Size: %d MB | Max Files: %d | Allowed: %s | Magic Number Check: %b | Max Dimensions: %dx%d | Max Pixels: %d MP"
            maxFileSizeInMB
            maxFilesPerUpload
            (String.Join(", ", allowedExtensions))
            validateMagicNumbers
            maxImageWidth
            maxImageHeight
            (int (maxImagePixels / 1000000L))
