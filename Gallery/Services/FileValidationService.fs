namespace Gallery.Services

open System
open System.IO
open System.Linq
open Microsoft.AspNetCore.Http
open Microsoft.Extensions.Configuration
open Microsoft.Extensions.Logging
open SixLabors.ImageSharp

type FileValidationService(configuration: IConfiguration, logger: ILogger<FileValidationService>) =

    let getConfigInt key defaultValue =
        match configuration.[key] with
        | null | "" -> defaultValue
        | value -> Int32.Parse(value)

    let getConfigInt64 key defaultValue =
        match configuration.[key] with
        | null | "" -> defaultValue
        | value -> Int64.Parse(value)

    let getConfigBool key defaultValue =
        match configuration.[key] with
        | null | "" -> defaultValue
        | value -> Boolean.Parse(value)

    let maxFileSizeInMB = getConfigInt "FileUpload:MaxFileSizeInMB" 10
    let maxFilesPerUpload = getConfigInt "FileUpload:MaxFilesPerUpload" 50
    let maxImageWidth = getConfigInt "FileUpload:MaxImageWidth" 10000
    let maxImageHeight = getConfigInt "FileUpload:MaxImageHeight" 10000
    let maxImagePixels = getConfigInt64 "FileUpload:MaxImagePixels" 50000000L
    let validateMagicNumbers = getConfigBool "FileUpload:ValidateMagicNumbers" true
    let validateImageDimensions = getConfigBool "FileUpload:ValidateImageDimensions" true

    let allowedExtensions =
        match configuration.GetSection("FileUpload:AllowedExtensions").Get<string[]>() with
        | null -> [|".jpg"; ".jpeg"; ".png"; ".webp"|]
        | arr -> arr

    let allowedMimeTypes =
        match configuration.GetSection("FileUpload:AllowedMimeTypes").Get<string[]>() with
        | null -> [|"image/jpeg"; "image/png"; "image/webp"|]
        | arr -> arr

    let jpegMagic = [| 0xFFuy; 0xD8uy; 0xFFuy |]
    let pngMagic = [| 0x89uy; 0x50uy; 0x4Euy; 0x47uy; 0x0Duy; 0x0Auy; 0x1Auy; 0x0Auy |]
    let webpMagic = [| 0x52uy; 0x49uy; 0x46uy; 0x46uy |]
    let gif87Magic = [| 0x47uy; 0x49uy; 0x46uy; 0x38uy; 0x37uy; 0x61uy |]
    let gif89Magic = [| 0x47uy; 0x49uy; 0x46uy; 0x38uy; 0x39uy; 0x61uy |]

    let startsWith (buffer: byte[]) (bufferLength: int) (magicNumber: byte[]) =
        bufferLength >= magicNumber.Length &&
        magicNumber |> Array.forall2 (=) buffer.[0..magicNumber.Length-1]

    let detectFormatFromMagic (buffer: byte[]) (bytesRead: int) =
        if startsWith buffer bytesRead jpegMagic then Some "JPEG"
        elif startsWith buffer bytesRead pngMagic then Some "PNG"
        elif startsWith buffer bytesRead webpMagic then Some "WebP"
        elif startsWith buffer bytesRead gif87Magic then Some "GIF87a"
        elif startsWith buffer bytesRead gif89Magic then Some "GIF89a"
        else None

    let validateFileName (file: IFormFile) =
        let fileName = Path.GetFileName(file.FileName)
        if String.IsNullOrWhiteSpace(fileName) then
            Error "Invalid file name"
        elif fileName.Contains("..") || fileName.Contains("/") || fileName.Contains("\\") then
            Error "File name contains invalid characters (possible path traversal attempt)"
        elif fileName.Length > 255 then
            Error "File name is too long (max 255 characters)"
        else
            Ok ()

    let validateFileSize (file: IFormFile) =
        let maxSizeBytes = int64 maxFileSizeInMB * 1024L * 1024L
        if file.Length = 0L then
            Error "File is empty"
        elif file.Length > maxSizeBytes then
            Error (sprintf "File size (%.2f MB) exceeds maximum allowed size (%d MB)"
                (float file.Length / 1024.0 / 1024.0) maxFileSizeInMB)
        else
            Ok ()

    let validateExtension (file: IFormFile) =
        let extension = Path.GetExtension(file.FileName).ToLowerInvariant()
        if String.IsNullOrEmpty(extension) then
            Error "File has no extension"
        elif not (allowedExtensions.Contains(extension)) then
            Error (sprintf "File extension '%s' is not allowed. Allowed: %s"
                extension (String.Join(", ", allowedExtensions)))
        else
            Ok ()

    let validateMimeType (file: IFormFile) =
        if String.IsNullOrEmpty(file.ContentType) then
            Error "File MIME type is missing"
        elif not (allowedMimeTypes.Contains(file.ContentType.ToLowerInvariant())) then
            Error (sprintf "MIME type '%s' is not allowed. Allowed: %s"
                file.ContentType (String.Join(", ", allowedMimeTypes)))
        else
            Ok ()

    let validateMagicNumberAndDimensions (file: IFormFile) =
        try
            use stream = file.OpenReadStream()
            let magicBuffer = Array.zeroCreate<byte> 8
            let bytesRead = stream.Read(magicBuffer, 0, 8)

            if bytesRead < 4 then
                Error "File is too small to validate"
            else
                let formatResult =
                    if not validateMagicNumbers then Ok "Skipped"
                    else
                        match detectFormatFromMagic magicBuffer bytesRead with
                        | Some format -> Ok format
                        | None -> Error "File content does not match any valid image format (invalid magic number)"

                match formatResult with
                | Error msg -> Error msg
                | Ok format when not validateImageDimensions -> Ok (format, 0, 0)
                | Ok format ->
                    stream.Position <- 0L
                    let imageInfo = Image.Identify(stream)

                    if isNull imageInfo then
                        Error "Unable to read image information"
                    else
                        let width, height = imageInfo.Width, imageInfo.Height
                        let totalPixels = int64 width * int64 height

                        logger.LogDebug("Image {FileName}: {Width}x{Height} ({Pixels} pixels)",
                            file.FileName, width, height, totalPixels)

                        if width > maxImageWidth then
                            Error (sprintf "Image width (%d) exceeds maximum allowed (%d)" width maxImageWidth)
                        elif height > maxImageHeight then
                            Error (sprintf "Image height (%d) exceeds maximum allowed (%d)" height maxImageHeight)
                        elif totalPixels > maxImagePixels then
                            Error (sprintf "Image size (%.1f MP) exceeds maximum allowed (%.1f MP). Possible decompression bomb."
                                (float totalPixels / 1000000.0) (float maxImagePixels / 1000000.0))
                        else
                            Ok (format, width, height)
        with
        | :? OutOfMemoryException as ex ->
            logger.LogError(ex, "Out of memory while processing image {FileName} - possible image bomb", file.FileName)
            Error "Image processing failed: out of memory (possible decompression bomb)"
        | ex ->
            logger.LogError(ex, "Error validating image {FileName}", file.FileName)
            Error (sprintf "Error reading image: %s" ex.Message)

    member _.ValidateFileCount(fileCount: int) =
        if fileCount = 0 then Error "No files provided"
        elif fileCount > maxFilesPerUpload then Error (sprintf "Too many files (%d). Maximum allowed: %d" fileCount maxFilesPerUpload)
        else Ok ()

    member _.ValidateFile(file: IFormFile) : Result<string, string> =
        validateFileName file
        |> Result.bind (fun _ -> validateFileSize file)
        |> Result.bind (fun _ -> validateExtension file)
        |> Result.bind (fun _ -> validateMimeType file)
        |> Result.bind (fun _ ->
            validateMagicNumberAndDimensions file
            |> Result.map (fun (format, width, height) ->
                if width > 0 && height > 0 then sprintf "%s (%dx%d)" format width height
                else format))

    member this.ValidateFiles(files: IFormFile list) : Result<unit, string list> =
        match this.ValidateFileCount(files.Length) with
        | Error msg -> Error [msg]
        | Ok _ ->
            let errors =
                files
                |> List.mapi (fun i file ->
                    match this.ValidateFile(file) with
                    | Ok _ -> None
                    | Error msg -> Some (sprintf "File %d (%s): %s" (i + 1) file.FileName msg))
                |> List.choose id

            if errors.IsEmpty then Ok ()
            else Error errors
