namespace Gallery.Services

open System
open System.IO
open System.Threading.Tasks
open Microsoft.Extensions.Logging
open SixLabors.ImageSharp
open SixLabors.ImageSharp.Processing
open SixLabors.ImageSharp.Formats.Jpeg

type ThumbnailSize =

    | Thumb
    | Small
    | Medium
    | Original

type ImageProcessingService(logger: ILogger<ImageProcessingService>) =

    let getMaxDimension (size: ThumbnailSize) =
        match size with
        | Thumb -> 200
        | Small -> 400
        | Medium -> 800
        | Original -> 0

    let getSuffix (size: ThumbnailSize) =
        match size with
        | Thumb -> "-thumb"
        | Small -> "-small"
        | Medium -> "-medium"
        | Original -> ""

    let thumbnailSizes = [| Thumb; Small; Medium |]

    let calculateDimensions (width: int) (height: int) (maxDimension: int) =
        if width > height then
            let ratio = float maxDimension / float width
            (maxDimension, int (float height * ratio))
        else
            let ratio = float maxDimension / float height
            (int (float width * ratio), maxDimension)

    member _.GetThumbnailFilename(originalFilename: string, size: ThumbnailSize) =
        let extension = Path.GetExtension(originalFilename)
        let nameWithoutExt = Path.GetFileNameWithoutExtension(originalFilename)
        let suffix = getSuffix size
        sprintf "%s%s%s" nameWithoutExt suffix extension

    member private _.ResizeAndSave(image: Image, destPath: string, maxDimension: int) =
        task {
            use clonedImage = image.Clone(fun ctx ->
                let (newWidth, newHeight) = calculateDimensions image.Width image.Height maxDimension
                ctx.Resize(newWidth, newHeight, KnownResamplers.Lanczos3) |> ignore
            )

            let encoder = JpegEncoder(Quality = Nullable(85))
            do! clonedImage.SaveAsync(destPath, encoder)
        }

    member private this.GenerateSingleThumbnail(image: Image, baseFilename: string, outputDirectory: string, size: ThumbnailSize) =
        task {
            try
                let maxDimension = getMaxDimension size
                let thumbFilename = this.GetThumbnailFilename(baseFilename, size)
                let thumbPath = Path.Combine(outputDirectory, thumbFilename)

                let (newWidth, newHeight) = calculateDimensions image.Width image.Height maxDimension

                do! this.ResizeAndSave(image, thumbPath, maxDimension)

                logger.LogDebug("Generated {Size} thumbnail: {Path} ({Width}x{Height})",
                    size, Path.GetFileName(thumbPath), newWidth, newHeight)

                return Ok (size, thumbFilename)
            with
            | ex ->
                logger.LogError(ex, "Error generating {Size} thumbnail", size)
                return Error (size, ex.Message)
        }

    member this.GenerateThumbnailsAsync(originalPath: string, baseFilename: string, outputDirectory: string) =
        task {
            try
                if not (File.Exists(originalPath)) then
                    return Error "Original file not found"
                else
                    use image = Image.Load(originalPath)

                    logger.LogDebug("Loaded image {Path} ({Width}x{Height}) for thumbnail generation",
                        originalPath, image.Width, image.Height)

                    let! results =
                        thumbnailSizes
                        |> Array.map (fun size -> this.GenerateSingleThumbnail(image, baseFilename, outputDirectory, size))
                        |> Task.WhenAll

                    let errors =
                        results
                        |> Array.choose (function
                            | Error (size, msg) -> Some (sprintf "%A: %s" size msg)
                            | Ok _ -> None)

                    if Array.isEmpty errors then
                        logger.LogInformation("Generated all thumbnails for {FileName}", baseFilename)
                        return Ok ()
                    else
                        let succeeded =
                            results
                            |> Array.choose (function
                                | Ok (_, filename) -> Some filename
                                | Error _ -> None)

                        for filename in succeeded do
                            let path = Path.Combine(outputDirectory, filename)
                            if File.Exists(path) then
                                try File.Delete(path) with _ -> ()

                        return Error (String.Join("; ", errors))
            with
            | ex ->
                logger.LogError(ex, "Error generating thumbnails for: {Path}", originalPath)
                return Error (sprintf "Failed to generate thumbnails: %s" ex.Message)
        }

    member this.DeleteThumbnailsAsync(baseFilename: string, directory: string) =
        task {
            try
                for size in thumbnailSizes do
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
