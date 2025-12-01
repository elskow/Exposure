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

[<Struct; NoComparison>]
type internal FileProcessingResult = {
    OriginalFile: IFormFile
    FileName: string
    FilePath: string
    Success: bool
    Error: string voption
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

    member private this.ProcessFileAsync(file: IFormFile, photosDir: string) =
        task {
            let extension = Path.GetExtension(file.FileName)
            let normalizedExtension = if extension.Equals(".jpeg", StringComparison.OrdinalIgnoreCase) then ".jpg" else extension.ToLowerInvariant()
            let uuid = Guid.NewGuid().ToString()
            let fileName = $"{uuid}{normalizedExtension}"
            let filePath = Path.Combine(photosDir, fileName)

            try
                use stream = new FileStream(filePath, FileMode.Create)
                do! file.CopyToAsync(stream)

                let! thumbnailResult = imageProcessing.GenerateThumbnailsAsync(filePath, fileName, photosDir)
                match thumbnailResult with
                | Error msg ->
                    try
                        if File.Exists(filePath) then File.Delete(filePath)
                        let! _ = imageProcessing.DeleteThumbnailsAsync(fileName, photosDir)
                        ()
                    with cleanupEx ->
                        logger.LogError(cleanupEx, "Cleanup failed after thumbnail error for {FileName}", file.FileName)

                    return { OriginalFile = file; FileName = fileName; FilePath = filePath; Success = false; Error = ValueSome $"Thumbnails failed: {msg}" }
                | Ok _ ->
                    return { OriginalFile = file; FileName = fileName; FilePath = filePath; Success = true; Error = ValueNone }
            with ex ->
                try
                    if File.Exists(filePath) then File.Delete(filePath)
                    let! _ = imageProcessing.DeleteThumbnailsAsync(fileName, photosDir)
                    ()
                with _ -> ()

                logger.LogError(ex, "File processing failed for {FileName}", file.FileName)
                return { OriginalFile = file; FileName = fileName; FilePath = filePath; Success = false; Error = ValueSome ex.Message }
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

                            let! currentMaxNum =
                                context.Photos
                                    .Where(fun p -> p.PlaceId = placeId)
                                    .Select(fun p -> p.PhotoNum :> obj)
                                    .MaxAsync(fun p -> p :?> Nullable<int>)

                            let startPhotoNum = if currentMaxNum.HasValue then currentMaxNum.Value + 1 else 1

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

                            let mutable uploadedCount = 0
                            let mutable lastError = ValueNone
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
                                        try
                                            if File.Exists(result.FilePath) then File.Delete(result.FilePath)
                                            let! _ = imageProcessing.DeleteThumbnailsAsync(result.FileName, photosDir)
                                            ()
                                        with cleanupEx ->
                                            logger.LogError(cleanupEx, "Cleanup failed after database error for {FileName}", result.FileName)
                                        lastError <- ValueSome $"Database error for {result.OriginalFile.FileName}"
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
                let! photoCount =
                    context.Photos
                        .Where(fun p -> p.PlaceId = placeId)
                        .CountAsync()

                if photoCount <> newOrder.Length then
                    logger.LogWarning("Reorder failed: photo count mismatch for placeId {PlaceId}. Expected {Expected}, got {Actual}", placeId, photoCount, newOrder.Length)
                    return false
                else
                    for (newNum, oldNum) in newOrder |> List.mapi (fun i oldNum -> (i + 1, oldNum)) do
                        let! _ =
                            context.Photos
                                .Where(fun p -> p.PlaceId = placeId && p.PhotoNum = oldNum)
                                .ExecuteUpdateAsync(fun setters ->
                                    setters.SetProperty((fun p -> p.PhotoNum), 10000 + newNum))
                        ()

                    let! _ =
                        context.Photos
                            .Where(fun p -> p.PlaceId = placeId && p.PhotoNum >= 10000)
                            .ExecuteUpdateAsync(fun setters ->
                                setters.SetProperty((fun p -> p.PhotoNum), (fun p -> p.PhotoNum - 10000)))

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
                if isFavorite then
                    let! cleared =
                        context.Photos
                            .Where(fun p -> p.PlaceId = placeId && p.IsFavorite)
                            .ExecuteUpdateAsync(fun setters ->
                                setters.SetProperty((fun p -> p.IsFavorite), false))
                    let! updated =
                        context.Photos
                            .Where(fun p -> p.PlaceId = placeId && p.PhotoNum = photoNum)
                            .ExecuteUpdateAsync(fun setters ->
                                setters.SetProperty((fun p -> p.IsFavorite), true))
                    if updated > 0 then
                        logger.LogInformation("Set favorite for placeId {PlaceId}, photoNum {PhotoNum}, cleared {Cleared}", placeId, photoNum, cleared)
                        return true
                    else
                        logger.LogWarning("Photo not found for favorite toggle: placeId {PlaceId}, photoNum {PhotoNum}", placeId, photoNum)
                        return false
                else
                    let! updated =
                        context.Photos
                            .Where(fun p -> p.PlaceId = placeId && p.PhotoNum = photoNum)
                            .ExecuteUpdateAsync(fun setters ->
                                setters.SetProperty((fun p -> p.IsFavorite), false))
                    if updated > 0 then
                        logger.LogInformation("Removed favorite for placeId {PlaceId}, photoNum {PhotoNum}", placeId, photoNum)
                        return true
                    else
                        logger.LogWarning("Photo not found for favorite toggle: placeId {PlaceId}, photoNum {PhotoNum}", placeId, photoNum)
                        return false
            finally
                uploadLock.Release() |> ignore
        }
