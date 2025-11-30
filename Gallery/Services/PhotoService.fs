namespace Gallery.Services

open System
open System.IO
open System.Linq
open System.Threading
open System.Threading.Tasks
open System.Collections.Concurrent
open Microsoft.AspNetCore.Http
open Microsoft.EntityFrameworkCore
open Microsoft.Extensions.Logging
open Gallery.Data
open Gallery.Models

/// Result type for parallel file processing
[<NoComparison>]
type internal FileProcessingResult = {
    OriginalFile: IFormFile
    FileName: string
    FilePath: string
    Success: bool
    Error: string option
}

type PhotoService(context: GalleryDbContext, webHostEnvironment: Microsoft.AspNetCore.Hosting.IWebHostEnvironment, fileValidation: FileValidationService, pathValidation: PathValidationService, malwareScanning: MalwareScanningService, slugGenerator: SlugGeneratorService, imageProcessing: ImageProcessingService, logger: ILogger<PhotoService>) =

    static let uploadLocks = new ConcurrentDictionary<int, SemaphoreSlim>()

    let getUploadLock(placeId: int) =
        uploadLocks.GetOrAdd(placeId, fun _ ->
            logger.LogDebug("Creating new upload lock for placeId {PlaceId}", placeId)
            new SemaphoreSlim(1, 1))

    let cleanupUploadLock(placeId: int) =
        match uploadLocks.TryRemove(placeId) with
        | true, semaphore ->
            logger.LogDebug("Disposing upload lock for deleted placeId {PlaceId}", placeId)
            semaphore.Dispose()
        | false, _ ->
            logger.LogDebug("No upload lock found for placeId {PlaceId} during cleanup", placeId)

    let getPhotoDirectory(placeId: int) =
        match pathValidation.CreateDirectorySafely(placeId) with
        | Ok path -> path
        | Error msg -> failwith $"Path validation failed: {msg}"

    /// Process a single file: copy to disk and generate thumbnails (I/O bound, can run in parallel)
    member private this.ProcessFileAsync(file: IFormFile, photosDir: string) =
        task {
            let extension = Path.GetExtension(file.FileName).ToLowerInvariant()
            let normalizedExtension = if extension = ".jpeg" then ".jpg" else extension
            let uuid = Guid.NewGuid().ToString()
            let fileName = $"{uuid}{normalizedExtension}"
            let filePath = Path.Combine(photosDir, fileName)

            try
                // Copy file to disk
                use stream = new FileStream(filePath, FileMode.Create)
                do! file.CopyToAsync(stream)

                // Generate thumbnails
                let! thumbnailResult = imageProcessing.GenerateThumbnailsAsync(filePath, fileName, photosDir)
                match thumbnailResult with
                | Error msg ->
                    // Cleanup on thumbnail failure
                    try
                        if File.Exists(filePath) then File.Delete(filePath)
                        let! _ = imageProcessing.DeleteThumbnailsAsync(fileName, photosDir)
                        ()
                    with cleanupEx ->
                        logger.LogError(cleanupEx, "Cleanup failed after thumbnail error for {FileName}", file.FileName)

                    return { OriginalFile = file; FileName = fileName; FilePath = filePath; Success = false; Error = Some $"Thumbnails failed: {msg}" }
                | Ok _ ->
                    return { OriginalFile = file; FileName = fileName; FilePath = filePath; Success = true; Error = None }
            with ex ->
                // Cleanup on any failure
                try
                    if File.Exists(filePath) then File.Delete(filePath)
                    let! _ = imageProcessing.DeleteThumbnailsAsync(fileName, photosDir)
                    ()
                with _ -> ()

                logger.LogError(ex, "File processing failed for {FileName}", file.FileName)
                return { OriginalFile = file; FileName = fileName; FilePath = filePath; Success = false; Error = Some ex.Message }
        }

    member this.UploadPhotosAsync(placeId: int, files: IFormFile list) =
        task {
            match fileValidation.ValidateFiles(files) with
            | Error errors ->
                let errorMessage = String.Join("; ", errors |> List.toArray)
                logger.LogWarning("File validation failed for placeId {PlaceId}: {Errors}", placeId, errorMessage)
                return Error errorMessage
            | Ok _ ->
                match! malwareScanning.ScanFilesAsync(files) with
                | Error scanError ->
                    logger.LogWarning("Malware scan failed for placeId {PlaceId}: {Error}", placeId, scanError)
                    return Error $"Malware scan failed: {scanError}"
                | Ok _ ->
                    let uploadLock = getUploadLock(placeId)
                    let! _ = uploadLock.WaitAsync()

                    try
                        let! place = context.Places.FindAsync(placeId)

                        if isNull place then
                            logger.LogWarning("Place not found for upload: {PlaceId}", placeId)
                            return Error "Place not found"
                        else
                            let photosDir = getPhotoDirectory(placeId)

                            // Get current max photo number
                            let! currentMaxNum =
                                context.Photos
                                    .Where(fun p -> p.PlaceId = placeId)
                                    .Select(fun p -> p.PhotoNum :> obj)
                                    .MaxAsync(fun p -> p :?> Nullable<int>)

                            let startPhotoNum = if currentMaxNum.HasValue then currentMaxNum.Value + 1 else 1

                            // PARALLEL PHASE: Process all files concurrently (I/O bound)
                            // Limit concurrency to avoid memory issues with large uploads
                            let validFiles = files |> List.filter (fun f -> f.Length > 0L)
                            let maxConcurrency = Math.Min(Environment.ProcessorCount, 4)
                            let semaphore = new SemaphoreSlim(maxConcurrency, maxConcurrency)

                            let processWithThrottle (file: IFormFile) =
                                task {
                                    let! _ = semaphore.WaitAsync()
                                    try
                                        return! this.ProcessFileAsync(file, photosDir)
                                    finally
                                        semaphore.Release() |> ignore
                                }

                            let! processingResults =
                                validFiles
                                |> List.map processWithThrottle
                                |> Task.WhenAll

                            semaphore.Dispose()

                            // SEQUENTIAL PHASE: Save to database (prevents race conditions)
                            let mutable uploadedCount = 0
                            let mutable lastError = None
                            let mutable photoNum = startPhotoNum

                            for result in processingResults do
                                if result.Success then
                                    try
                                        let slugExists (slug: string) =
                                            context.Photos.Any(fun p -> p.PlaceId = placeId && p.Slug = slug)
                                        let photoSlug = slugGenerator.GenerateUniqueSlug(slugExists)

                                        let photo = Photo()
                                        photo.PlaceId <- placeId
                                        photo.PhotoNum <- photoNum
                                        photo.Slug <- photoSlug
                                        photo.FileName <- result.FileName
                                        photo.CreatedAt <- DateTime.UtcNow

                                        context.Photos.Add(photo) |> ignore
                                        let! _ = context.SaveChangesAsync()

                                        uploadedCount <- uploadedCount + 1
                                        photoNum <- photoNum + 1
                                        logger.LogInformation("Saved photo {PhotoNum} for placeId {PlaceId}: {FileName}", photo.PhotoNum, placeId, result.FileName)
                                    with dbEx ->
                                        logger.LogError(dbEx, "Database save failed for {FileName}, cleaning up", result.FileName)
                                        // Cleanup file on DB failure
                                        try
                                            if File.Exists(result.FilePath) then File.Delete(result.FilePath)
                                            let! _ = imageProcessing.DeleteThumbnailsAsync(result.FileName, photosDir)
                                            ()
                                        with cleanupEx ->
                                            logger.LogError(cleanupEx, "Cleanup failed after database error for {FileName}", result.FileName)
                                        lastError <- Some $"Database error for {result.OriginalFile.FileName}"
                                else
                                    lastError <- result.Error

                            if uploadedCount = 0 && lastError.IsSome then
                                return Error lastError.Value
                            else
                                logger.LogInformation("Successfully uploaded {Count} photos to placeId {PlaceId}", uploadedCount, placeId)
                                return Ok uploadedCount
                    finally
                        uploadLock.Release() |> ignore
        }

    member this.DeletePhotoAsync(placeId: int, photoNum: int) =
        task {
            let uploadLock = getUploadLock(placeId)
            let! _ = uploadLock.WaitAsync()

            try
                let! photo =
                    context.Photos
                        .AsTracking()
                        .FirstOrDefaultAsync(fun p -> p.PlaceId = placeId && p.PhotoNum = photoNum)

                if isNull photo then
                    logger.LogWarning("Photo not found for deletion: placeId {PlaceId}, photoNum {PhotoNum}", placeId, photoNum)
                    return false
                else
                    match pathValidation.GetValidatedExistingPhotoPath(placeId, photo.FileName) with
                    | Ok filePath ->
                        if File.Exists(filePath) then
                            File.Delete(filePath)

                        let directory = Path.GetDirectoryName(filePath)
                        let! _ = imageProcessing.DeleteThumbnailsAsync(photo.FileName, directory)
                        ()
                    | Error msg ->
                        logger.LogWarning("Path validation error during delete for placeId {PlaceId}: {Error}", placeId, msg)

                    context.Photos.Remove(photo) |> ignore
                    let! _ = context.SaveChangesAsync()

                    // Bulk update remaining photos - single SQL UPDATE instead of N individual updates
                    let! updated =
                        context.Photos
                            .Where(fun p -> p.PlaceId = placeId && p.PhotoNum > photoNum)
                            .ExecuteUpdateAsync(fun setters ->
                                setters.SetProperty((fun p -> p.PhotoNum), (fun p -> p.PhotoNum - 1)))

                    logger.LogInformation("Deleted photo {PhotoNum} from placeId {PlaceId}, renumbered {Count} photos", photoNum, placeId, updated)
                    return true
            finally
                uploadLock.Release() |> ignore
        }

    member this.ReorderPhotosAsync(placeId: int, newOrder: int list) =
        task {
            let uploadLock = getUploadLock(placeId)
            let! _ = uploadLock.WaitAsync()

            try
                // Use AsTracking() to override the default NoTracking behavior for updates
                let! photos =
                    context.Photos
                        .AsTracking()
                        .Where(fun p -> p.PlaceId = placeId)
                        .ToListAsync()

                if photos.Count <> newOrder.Length then
                    logger.LogWarning("Reorder failed: photo count mismatch for placeId {PlaceId}. Expected {Expected}, got {Actual}", placeId, photos.Count, newOrder.Length)
                    return false
                else
                    // First pass: set temporary numbers to avoid conflicts
                    for (newNum, oldNum) in newOrder |> List.mapi (fun i oldNum -> (i + 1, oldNum)) do
                        let photo = photos.FirstOrDefault(fun p -> p.PhotoNum = oldNum)
                        if not (isNull photo) then
                            photo.PhotoNum <- 10000 + newNum

                    let! _ = context.SaveChangesAsync()

                    // Second pass: set final numbers
                    for photo in photos do
                        if photo.PhotoNum >= 10000 then
                            photo.PhotoNum <- photo.PhotoNum - 10000

                    let! _ = context.SaveChangesAsync()
                    logger.LogInformation("Reordered photos for placeId {PlaceId}", placeId)
                    return true
            finally
                uploadLock.Release() |> ignore
        }

    member _.GetPhotosForPlaceAsync(placeId: int) =
        task {
            let! photos =
                context.Photos
                    .AsNoTracking()
                    .Where(fun p -> p.PlaceId = placeId)
                    .OrderBy(fun p -> p.PhotoNum)
                    .ToListAsync()

            return photos |> List.ofSeq
        }

    member this.DeletePlaceWithPhotosAsync(placeId: int, deletePlaceFunc: int -> Task<bool>) =
        task {
            let uploadLock = getUploadLock(placeId)
            let! _ = uploadLock.WaitAsync()

            try
                match pathValidation.DeleteDirectorySafely(placeId) with
                | Ok _ ->
                    logger.LogInformation("Deleted photos directory for placeId {PlaceId}", placeId)
                | Error msg ->
                    logger.LogWarning("Failed to delete photos directory for placeId {PlaceId}: {Error}", placeId, msg)

                let! success = deletePlaceFunc(placeId)

                if success then
                    logger.LogInformation("Successfully deleted place {PlaceId} with all photos", placeId)
                else
                    logger.LogWarning("Failed to delete place {PlaceId} from database", placeId)

                return success
            finally
                uploadLock.Release() |> ignore
                cleanupUploadLock(placeId)
        }

    member this.SetFavoriteAsync(placeId: int, photoNum: int, isFavorite: bool) =
        task {
            let uploadLock = getUploadLock(placeId)
            let! _ = uploadLock.WaitAsync()

            try
                let! photo =
                    context.Photos
                        .AsTracking()
                        .FirstOrDefaultAsync(fun p -> p.PlaceId = placeId && p.PhotoNum = photoNum)

                if isNull photo then
                    logger.LogWarning("Photo not found for favorite toggle: placeId {PlaceId}, photoNum {PhotoNum}", placeId, photoNum)
                    return false
                else
                    if isFavorite then
                        let! _ =
                            context.Photos
                                .Where(fun p -> p.PlaceId = placeId && p.PhotoNum <> photoNum && p.IsFavorite)
                                .ExecuteUpdateAsync(fun setters ->
                                    setters.SetProperty((fun p -> p.IsFavorite), false))
                        ()

                    photo.IsFavorite <- isFavorite
                    let! _ = context.SaveChangesAsync()
                    logger.LogInformation("Set favorite for placeId {PlaceId}, photoNum {PhotoNum}: {IsFavorite}", placeId, photoNum, isFavorite)
                    return true
            finally
                uploadLock.Release() |> ignore
        }
