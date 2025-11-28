namespace Gallery.Services

open System
open System.IO
open System.Linq
open Microsoft.AspNetCore.Http
open Microsoft.Extensions.Configuration
open Microsoft.Extensions.Logging
open SixLabors.ImageSharp

type FileValidationService(configuration: IConfiguration, logger: ILogger<FileValidationService>) =

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
        if String.IsNullOrEmpty(configValue) then 50000000L else Int64.Parse(configValue)

    let validateImageDimensions =
        let configValue = configuration.["FileUpload:ValidateImageDimensions"]
        if String.IsNullOrEmpty(configValue) then true else Boolean.Parse(configValue)

    let jpegMagic = [| 0xFFuy; 0xD8uy; 0xFFuy |]
    let pngMagic = [| 0x89uy; 0x50uy; 0x4Euy; 0x47uy; 0x0Duy; 0x0Auy; 0x1Auy; 0x0Auy |]
    let webpMagic = [| 0x52uy; 0x49uy; 0x46uy; 0x46uy |]
    let gif87Magic = [| 0x47uy; 0x49uy; 0x46uy; 0x38uy; 0x37uy; 0x61uy |]
    let gif89Magic = [| 0x47uy; 0x49uy; 0x46uy; 0x38uy; 0x39uy; 0x61uy |]

    let startsWith (buffer: byte[]) (bufferLength: int) (magicNumber: byte[]) =
        if bufferLength < magicNumber.Length then
            false
        else
            let mutable matches = true
            let mutable i = 0
            while matches && i < magicNumber.Length do
                if buffer.[i] <> magicNumber.[i] then
                    matches <- false
                i <- i + 1
            matches

    let detectFormatFromMagic (buffer: byte[]) (bytesRead: int) =
        if startsWith buffer bytesRead jpegMagic then Some "JPEG"
        elif startsWith buffer bytesRead pngMagic then Some "PNG"
        elif startsWith buffer bytesRead webpMagic then Some "WebP"
        elif startsWith buffer bytesRead gif87Magic then Some "GIF87a"
        elif startsWith buffer bytesRead gif89Magic then Some "GIF89a"
        else None

    member _.ValidateExtension(file: IFormFile) : Result<unit, string> =
        let extension = Path.GetExtension(file.FileName).ToLowerInvariant()

        if String.IsNullOrEmpty(extension) then
            Error "File has no extension"
        elif not (allowedExtensions.Contains(extension)) then
            Error (sprintf "File extension '%s' is not allowed. Allowed: %s"
                extension (String.Join(", ", allowedExtensions)))
        else
            Ok ()

    member _.ValidateMimeType(file: IFormFile) : Result<unit, string> =
        if String.IsNullOrEmpty(file.ContentType) then
            Error "File MIME type is missing"
        elif not (allowedMimeTypes.Contains(file.ContentType.ToLowerInvariant())) then
            Error (sprintf "MIME type '%s' is not allowed. Allowed: %s"
                file.ContentType (String.Join(", ", allowedMimeTypes)))
        else
            Ok ()

    member _.ValidateFileSize(file: IFormFile) : Result<unit, string> =
        let maxSizeBytes = int64 maxFileSizeInMB * 1024L * 1024L

        if file.Length = 0L then
            Error "File is empty"
        elif file.Length > maxSizeBytes then
            Error (sprintf "File size (%.2f MB) exceeds maximum allowed size (%d MB)"
                (float file.Length / 1024.0 / 1024.0) maxFileSizeInMB)
        else
            Ok ()

    member _.ValidateFileCount(fileCount: int) : Result<unit, string> =
        if fileCount = 0 then
            Error "No files provided"
        elif fileCount > maxFilesPerUpload then
            Error (sprintf "Too many files (%d). Maximum allowed: %d" fileCount maxFilesPerUpload)
        else
            Ok ()

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

    member _.ValidateMagicNumberAndDimensions(file: IFormFile) : Result<string * int * int, string> =
        try
            use stream = file.OpenReadStream()

            let magicBuffer = Array.zeroCreate<byte> 8
            let bytesRead = stream.Read(magicBuffer, 0, 8)

            if bytesRead < 4 then
                Error "File is too small to validate"
            else
                let formatResult =
                    if validateMagicNumbers then
                        match detectFormatFromMagic magicBuffer bytesRead with
                        | Some format -> Ok format
                        | None -> Error "File content does not match any valid image format (invalid magic number)"
                    else
                        Ok "Skipped"

                match formatResult with
                | Error msg -> Error msg
                | Ok format ->
                    if not validateImageDimensions then
                        Ok (format, 0, 0)
                    else
                        stream.Position <- 0L

                        let imageInfo = Image.Identify(stream)

                        if isNull imageInfo then
                            Error "Unable to read image information"
                        else
                            let width = imageInfo.Width
                            let height = imageInfo.Height
                            let totalPixels = int64 width * int64 height

                            logger.LogDebug("Image {FileName}: {Width}x{Height} ({Pixels} pixels)",
                                file.FileName, width, height, totalPixels)

                            if width > maxImageWidth then
                                Error (sprintf "Image width (%d) exceeds maximum allowed (%d)" width maxImageWidth)
                            elif height > maxImageHeight then
                                Error (sprintf "Image height (%d) exceeds maximum allowed (%d)" height maxImageHeight)
                            elif totalPixels > maxImagePixels then
                                let megapixels = float totalPixels / 1000000.0
                                let maxMegapixels = float maxImagePixels / 1000000.0
                                Error (sprintf "Image size (%.1f MP) exceeds maximum allowed (%.1f MP). Possible decompression bomb."
                                    megapixels maxMegapixels)
                            else
                                Ok (format, width, height)
        with
        | :? OutOfMemoryException as ex ->
            logger.LogError(ex, "Out of memory while processing image {FileName} - possible image bomb", file.FileName)
            Error "Image processing failed: out of memory (possible decompression bomb)"
        | ex ->
            logger.LogError(ex, "Error validating image {FileName}", file.FileName)
            Error (sprintf "Error reading image: %s" ex.Message)

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
                        match this.ValidateMagicNumberAndDimensions(file) with
                        | Error msg -> Error msg
                        | Ok (format, width, height) ->
                            if width > 0 && height > 0 then
                                Ok (sprintf "%s (%dx%d)" format width height)
                            else
                                Ok format

    member this.ValidateFiles(files: IFormFile list) : Result<unit, string list> =
        match this.ValidateFileCount(files.Length) with
        | Error msg -> Error [msg]
        | Ok _ ->
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
