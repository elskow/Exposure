namespace Gallery.Services

open System
open System.IO
open System.Threading.Tasks
open Microsoft.Extensions.Logging
open SixLabors.ImageSharp
open SixLabors.ImageSharp.Processing
open SixLabors.ImageSharp.Formats.Jpeg

type ThumbnailSize =
    | Thumb     // 200x200 - for lists and tiny previews
    | Small     // 400x400 - for grid views
    | Medium    // 800x800 - for modal previews
    | Original  // Full size - for detail view

type ImageProcessingService(logger: ILogger<ImageProcessingService>) =

    // Get max dimension for thumbnail size
    let getMaxDimension (size: ThumbnailSize) =
        match size with
        | Thumb -> 200
        | Small -> 400
        | Medium -> 800
        | Original -> 0 // Not used for original

    // Get suffix for thumbnail filename
    let getSuffix (size: ThumbnailSize) =
        match size with
        | Thumb -> "-thumb"
        | Small -> "-small"
        | Medium -> "-medium"
        | Original -> ""

    // Generate thumbnail filename from original
    member _.GetThumbnailFilename(originalFilename: string, size: ThumbnailSize) =
        let extension = Path.GetExtension(originalFilename)
        let nameWithoutExt = Path.GetFileNameWithoutExtension(originalFilename)
        let suffix = getSuffix size
        sprintf "%s%s%s" nameWithoutExt suffix extension

    // Resize image to fit within max dimension while maintaining aspect ratio
    member private this.ResizeImage(sourcePath: string, destPath: string, maxDimension: int) =
        task {
            try
                use image = Image.Load(sourcePath)

                // Calculate new dimensions maintaining aspect ratio
                let width = image.Width
                let height = image.Height

                let (newWidth, newHeight) =
                    if width > height then
                        let ratio = float maxDimension / float width
                        (maxDimension, int (float height * ratio))
                    else
                        let ratio = float maxDimension / float height
                        (int (float width * ratio), maxDimension)

                logger.LogDebug("Resizing image from {OriginalWidth}x{OriginalHeight} to {NewWidth}x{NewHeight}",
                    width, height, newWidth, newHeight)

                // Resize with high quality settings
                image.Mutate(fun x ->
                    x.Resize(newWidth, newHeight, KnownResamplers.Lanczos3) |> ignore
                )

                // Save with JPEG quality of 85
                let encoder = JpegEncoder(Quality = Nullable(85))
                do! image.SaveAsync(destPath, encoder)

                logger.LogInformation("Generated thumbnail: {Path} ({Width}x{Height})",
                    Path.GetFileName(destPath), newWidth, newHeight)

                return Ok ()
            with
            | ex ->
                logger.LogError(ex, "Error generating thumbnail: {Path}", destPath)
                return Error (sprintf "Failed to generate thumbnail: %s" ex.Message)
        }

    // Generate all thumbnail sizes for an image
    member this.GenerateThumbnailsAsync(originalPath: string, baseFilename: string, outputDirectory: string) =
        task {
            try
                // Verify original file exists
                if not (File.Exists(originalPath)) then
                    return Error "Original file not found"
                else
                    let mutable errors = []

                    // Generate thumb (200x200)
                    let thumbFilename = this.GetThumbnailFilename(baseFilename, Thumb)
                    let thumbPath = Path.Combine(outputDirectory, thumbFilename)
                    let! thumbResult = this.ResizeImage(originalPath, thumbPath, getMaxDimension Thumb)
                    match thumbResult with
                    | Error msg -> errors <- msg :: errors
                    | Ok _ -> ()

                    // Generate small (400x400)
                    let smallFilename = this.GetThumbnailFilename(baseFilename, Small)
                    let smallPath = Path.Combine(outputDirectory, smallFilename)
                    let! smallResult = this.ResizeImage(originalPath, smallPath, getMaxDimension Small)
                    match smallResult with
                    | Error msg -> errors <- msg :: errors
                    | Ok _ -> ()

                    // Generate medium (800x800)
                    let mediumFilename = this.GetThumbnailFilename(baseFilename, Medium)
                    let mediumPath = Path.Combine(outputDirectory, mediumFilename)
                    let! mediumResult = this.ResizeImage(originalPath, mediumPath, getMaxDimension Medium)
                    match mediumResult with
                    | Error msg -> errors <- msg :: errors
                    | Ok _ -> ()

                    if List.isEmpty errors then
                        return Ok ()
                    else
                        return Error (String.Join("; ", errors))
            with
            | ex ->
                logger.LogError(ex, "Error generating thumbnails for: {Path}", originalPath)
                return Error (sprintf "Failed to generate thumbnails: %s" ex.Message)
        }

    // Delete all thumbnails for a file
    member this.DeleteThumbnailsAsync(baseFilename: string, directory: string) =
        task {
            try
                let sizes = [Thumb; Small; Medium]

                for size in sizes do
                    let thumbFilename = this.GetThumbnailFilename(baseFilename, size)
                    let thumbPath = Path.Combine(directory, thumbFilename)

                    if File.Exists(thumbPath) then
                        File.Delete(thumbPath)
                        logger.LogDebug("Deleted thumbnail: {Path}", thumbPath)

                return Ok ()
            with
            | ex ->
                logger.LogError(ex, "Error deleting thumbnails for: {File}", baseFilename)
                return Error (sprintf "Failed to delete thumbnails: %s" ex.Message)
        }

    // Check if image needs thumbnail generation (file is larger than threshold)
    member _.ShouldGenerateThumbnails(width: int, height: int) =
        // Generate thumbnails if image is larger than small size (400px)
        width > 400 || height > 400
