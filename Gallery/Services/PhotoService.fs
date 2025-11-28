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
        | Error msg -> failwith (sprintf "Path validation failed: %s" msg)

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
                    return Error (sprintf "Malware scan failed: %s" scanError)
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
                            let mutable uploadedCount = 0
                            let mutable lastError = None

                            let! currentMaxNum =
                                context.Photos
                                    .Where(fun p -> p.PlaceId = placeId)
                                    .Select(fun p -> p.PhotoNum :> obj)
                                    .MaxAsync(fun p -> p :?> Nullable<int>)

                            let mutable nextPhotoNum =
                                if currentMaxNum.HasValue then currentMaxNum.Value + 1 else 1

                            for file in files do
                                if file.Length > 0L then
                                    let mutable filePath = ""
                                    let mutable fileName = ""
                                    let mutable filesCreated = false

                                    try
                                        let photoNum = nextPhotoNum
                                        nextPhotoNum <- nextPhotoNum + 1

                                        let extension = Path.GetExtension(file.FileName).ToLowerInvariant()
                                        let normalizedExtension = if extension = ".jpeg" then ".jpg" else extension
                                        let uuid = Guid.NewGuid().ToString()
                                        fileName <- sprintf "%s%s" uuid normalizedExtension
                                        filePath <- Path.Combine(photosDir, fileName)

                                        use stream = new FileStream(filePath, FileMode.Create)
                                        do! file.CopyToAsync(stream)
                                        filesCreated <- true

                                        let! thumbnailResult = imageProcessing.GenerateThumbnailsAsync(filePath, fileName, photosDir)
                                        match thumbnailResult with
                                        | Error msg ->
                                            try
                                                if File.Exists(filePath) then File.Delete(filePath)
                                                let! _ = imageProcessing.DeleteThumbnailsAsync(fileName, photosDir)
                                                ()
                                            with cleanupEx ->
                                                logger.LogError(cleanupEx, "Cleanup failed after thumbnail error for {FileName}", file.FileName)

                                            filesCreated <- false
                                            nextPhotoNum <- nextPhotoNum - 1
                                            lastError <- Some (sprintf "Failed to generate thumbnails for %s: %s" file.FileName msg)
                                            logger.LogError("Thumbnail generation failed for {FileName}: {Error}", file.FileName, msg)
                                        | Ok _ ->
                                            let slugExists (slug: string) =
                                                context.Photos.Any(fun p -> p.PlaceId = placeId && p.Slug = slug)
                                            let photoSlug = slugGenerator.GenerateUniqueSlug(slugExists)

                                            let photo = Photo()
                                            photo.PlaceId <- placeId
                                            photo.PhotoNum <- photoNum
                                            photo.Slug <- photoSlug
                                            photo.FileName <- fileName
                                            photo.CreatedAt <- DateTime.UtcNow

                                            context.Photos.Add(photo) |> ignore

                                            try
                                                let! _ = context.SaveChangesAsync()
                                                uploadedCount <- uploadedCount + 1
                                                filesCreated <- false
                                                logger.LogInformation("Uploaded photo {PhotoNum} for placeId {PlaceId}: {FileName}", photoNum, placeId, fileName)
                                            with
                                            | dbEx ->
                                                logger.LogError(dbEx, "Database save failed for {FileName}, cleaning up", file.FileName)
                                                nextPhotoNum <- nextPhotoNum - 1
                                                try
                                                    if File.Exists(filePath) then File.Delete(filePath)
                                                    let! _ = imageProcessing.DeleteThumbnailsAsync(fileName, photosDir)
                                                    ()
                                                with cleanupEx ->
                                                    logger.LogError(cleanupEx, "Cleanup failed after database error for {FileName}", file.FileName)
                                                raise dbEx
                                    with
                                    | ex ->
                                        if filesCreated then
                                            try
                                                logger.LogWarning("Exception during upload, cleaning up files for {FileName}", file.FileName)
                                                if File.Exists(filePath) then File.Delete(filePath)
                                                let! _ = imageProcessing.DeleteThumbnailsAsync(fileName, photosDir)
                                                ()
                                            with cleanupEx ->
                                                logger.LogError(cleanupEx, "Cleanup failed in exception handler for {FileName}", file.FileName)

                                        lastError <- Some (sprintf "Failed to upload %s: %s" file.FileName ex.Message)
                                        logger.LogError(ex, "Upload error for {FileName}", file.FileName)

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
                    context.Photos.FirstOrDefaultAsync(fun p -> p.PlaceId = placeId && p.PhotoNum = photoNum)

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

                    let! remainingPhotos =
                        context.Photos
                            .Where(fun p -> p.PlaceId = placeId && p.PhotoNum > photoNum)
                            .OrderBy(fun p -> p.PhotoNum :> obj)
                            .ToListAsync()

                    for remainingPhoto in remainingPhotos do
                        remainingPhoto.PhotoNum <- remainingPhoto.PhotoNum - 1

                    let! _ = context.SaveChangesAsync()
                    logger.LogInformation("Deleted photo {PhotoNum} from placeId {PlaceId}", photoNum, placeId)
                    return true
            finally
                uploadLock.Release() |> ignore
        }

    member this.ReorderPhotosAsync(placeId: int, newOrder: int list) =
        task {
            let uploadLock = getUploadLock(placeId)
            let! _ = uploadLock.WaitAsync()

            try
                let! photos =
                    context.Photos
                        .Where(fun p -> p.PlaceId = placeId)
                        .ToListAsync()

                if photos.Count <> newOrder.Length then
                    logger.LogWarning("Reorder failed: photo count mismatch for placeId {PlaceId}. Expected {Expected}, got {Actual}", placeId, photos.Count, newOrder.Length)
                    return false
                else
                    for (newNum, oldNum) in newOrder |> List.mapi (fun i oldNum -> (i + 1, oldNum)) do
                        let photo = photos.FirstOrDefault(fun p -> p.PhotoNum = oldNum)
                        if not (isNull photo) then
                            photo.PhotoNum <- 10000 + newNum

                    let! _ = context.SaveChangesAsync()

                    for photo in photos do
                        if photo.PhotoNum >= 10000 then
                            photo.PhotoNum <- photo.PhotoNum - 10000

                    let! _ = context.SaveChangesAsync()
                    logger.LogInformation("Reordered photos for placeId {PlaceId}", placeId)
                    return true
            finally
                uploadLock.Release() |> ignore
        }

    member this.GetPhotosForPlaceAsync(placeId: int) =
        task {
            let! photos =
                context.Photos
                    .AsNoTracking()
                    .Where(fun p -> p.PlaceId = placeId)
                    .OrderBy(fun p -> p.PhotoNum :> obj)
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
                    context.Photos.FirstOrDefaultAsync(fun p -> p.PlaceId = placeId && p.PhotoNum = photoNum)

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
