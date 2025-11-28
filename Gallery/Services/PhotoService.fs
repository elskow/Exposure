namespace Gallery.Services

open System
open System.IO
open System.Linq
open System.Threading
open System.Threading.Tasks
open System.Collections.Concurrent
open Microsoft.AspNetCore.Http
open Microsoft.EntityFrameworkCore
open Gallery.Data
open Gallery.Models

type PhotoService(context: GalleryDbContext, webHostEnvironment: Microsoft.AspNetCore.Hosting.IWebHostEnvironment, fileValidation: FileValidationService, pathValidation: PathValidationService, malwareScanning: MalwareScanningService, slugGenerator: SlugGeneratorService, imageProcessing: ImageProcessingService) =

    // Dictionary to hold semaphores per placeId to prevent concurrent uploads to same place
    static let uploadLocks = new ConcurrentDictionary<int, SemaphoreSlim>()

    // Get or create a semaphore for a specific place
    let getUploadLock(placeId: int) =
        uploadLocks.GetOrAdd(placeId, fun _ -> new SemaphoreSlim(1, 1))

    let getPhotoDirectory(placeId: int) =
        match pathValidation.CreateDirectorySafely(placeId) with
        | Ok path -> path
        | Error msg -> failwith (sprintf "Path validation failed: %s" msg)

    // Upload photos for a place
    member this.UploadPhotosAsync(placeId: int, files: IFormFile list) =
        task {
            // Validate all files first before processing
            match fileValidation.ValidateFiles(files) with
            | Error errors ->
                let errorMessage = String.Join("; ", errors |> List.toArray)
                return Error errorMessage
            | Ok _ ->
                // Scan for malware
                match! malwareScanning.ScanFilesAsync(files) with
                | Error scanError ->
                    return Error (sprintf "Malware scan failed: %s" scanError)
                | Ok _ ->
                    // Get semaphore lock for this place to prevent race conditions
                    let uploadLock = getUploadLock(placeId)
                    let! _ = uploadLock.WaitAsync()

                    try
                        let! place = context.Places.FindAsync(placeId)

                        if isNull place then
                            return Error "Place not found"
                        else
                            let photosDir = getPhotoDirectory(placeId)
                            let mutable uploadedCount = 0
                            let mutable lastError = None

                            for file in files do
                                if file.Length > 0L then
                                    let mutable filePath = ""
                                    let mutable fileName = ""
                                    let mutable filesCreated = false

                                    try
                                        // Get current max PhotoNum from database (prevents race conditions)
                                        let! photosList =
                                            context.Photos
                                                .Where(fun p -> p.PlaceId = placeId)
                                                .ToListAsync()

                                        let currentMaxNum =
                                            if photosList.Count = 0 then
                                                0
                                            else
                                                photosList |> Seq.map (fun p -> p.PhotoNum) |> Seq.max

                                        let photoNum = currentMaxNum + 1
                                        let extension = Path.GetExtension(file.FileName).ToLowerInvariant()
                                        // Normalize extension to .jpg if it's .jpeg
                                        let normalizedExtension = if extension = ".jpeg" then ".jpg" else extension
                                        // Generate UUID-based filename
                                        let uuid = Guid.NewGuid().ToString()
                                        fileName <- sprintf "%s%s" uuid normalizedExtension
                                        filePath <- Path.Combine(photosDir, fileName)

                                        // Write file to disk
                                        use stream = new FileStream(filePath, FileMode.Create)
                                        do! file.CopyToAsync(stream)
                                        stream.Close()
                                        filesCreated <- true  // Mark that files exist on disk

                                        // Generate thumbnails for the uploaded image
                                        let! thumbnailResult = imageProcessing.GenerateThumbnailsAsync(filePath, fileName, photosDir)
                                        match thumbnailResult with
                                        | Error msg ->
                                            // Thumbnail generation failed - delete the original file and ALL thumbnails
                                            try
                                                if File.Exists(filePath) then File.Delete(filePath)
                                                let! _ = imageProcessing.DeleteThumbnailsAsync(fileName, photosDir)
                                                ()
                                            with cleanupEx ->
                                                printfn "Cleanup failed after thumbnail error: %s" cleanupEx.Message

                                            filesCreated <- false  // Files cleaned up
                                            lastError <- Some (sprintf "Failed to generate thumbnails for %s: %s" file.FileName msg)
                                            printfn "Error: %s" (lastError.Value)
                                        | Ok _ ->
                                            // Generate unique slug for this photo within the place
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
                                                // Save immediately to prevent race conditions with concurrent uploads
                                                let! _ = context.SaveChangesAsync()
                                                uploadedCount <- uploadedCount + 1
                                                filesCreated <- false  // Success! Don't clean up
                                            with
                                            | dbEx ->
                                                // Database save failed - clean up the files we just created
                                                printfn "Database save failed, cleaning up files for %s: %s" file.FileName dbEx.Message
                                                try
                                                    if File.Exists(filePath) then File.Delete(filePath)
                                                    let! _ = imageProcessing.DeleteThumbnailsAsync(fileName, photosDir)
                                                    ()
                                                with cleanupEx ->
                                                    printfn "Cleanup failed after database error: %s" cleanupEx.Message
                                                raise dbEx
                                    with
                                    | ex ->
                                        // If anything fails, ensure cleanup and record error
                                        if filesCreated then
                                            try
                                                printfn "Exception during upload, cleaning up files for %s" file.FileName
                                                if File.Exists(filePath) then File.Delete(filePath)
                                                let! _ = imageProcessing.DeleteThumbnailsAsync(fileName, photosDir)
                                                ()
                                            with cleanupEx ->
                                                printfn "Cleanup failed in exception handler: %s" cleanupEx.Message

                                        lastError <- Some (sprintf "Failed to upload %s: %s" file.FileName ex.Message)
                                        printfn "Upload error: %s" (lastError.Value)

                            if uploadedCount = 0 && lastError.IsSome then
                                return Error lastError.Value
                            else
                                return Ok uploadedCount
                    finally
                        uploadLock.Release() |> ignore
        }

    // Delete a photo
    member this.DeletePhotoAsync(placeId: int, photoNum: int) =
        task {
            // Acquire lock to prevent race conditions with uploads/reorders
            let uploadLock = getUploadLock(placeId)
            let! _ = uploadLock.WaitAsync()

            try
                let! photo =
                    context.Photos.FirstOrDefaultAsync(fun p -> p.PlaceId = placeId && p.PhotoNum = photoNum)

                if isNull photo then
                    return false
                else
                    // Delete file and thumbnails from filesystem with path validation
                    match pathValidation.GetValidatedExistingPhotoPath(placeId, photo.FileName) with
                    | Ok filePath ->
                        if File.Exists(filePath) then
                            File.Delete(filePath)

                        // Delete thumbnails
                        let directory = Path.GetDirectoryName(filePath)
                        let! _ = imageProcessing.DeleteThumbnailsAsync(photo.FileName, directory)
                        ()
                    | Error msg ->
                        printfn "Path validation error during delete: %s" msg

                    // Delete from database
                    context.Photos.Remove(photo) |> ignore
                    let! _ = context.SaveChangesAsync()

                    // Reorder remaining photos
                    let! remainingPhotos =
                        context.Photos
                            .Where(fun p -> p.PlaceId = placeId && p.PhotoNum > photoNum)
                            .OrderBy(fun p -> p.PhotoNum :> obj)
                            .ToListAsync()

                    for remainingPhoto in remainingPhotos do
                        let newNum = remainingPhoto.PhotoNum - 1
                        // Update PhotoNum but keep the same UUID-based filename
                        remainingPhoto.PhotoNum <- newNum

                    let! _ = context.SaveChangesAsync()
                    return true
            finally
                uploadLock.Release() |> ignore
        }

    // Reorder photos
    member this.ReorderPhotosAsync(placeId: int, newOrder: int list) =
        task {
            // Acquire lock to prevent race conditions with uploads/deletes
            let uploadLock = getUploadLock(placeId)
            let! _ = uploadLock.WaitAsync()

            try
                let! photos =
                    context.Photos
                        .Where(fun p -> p.PlaceId = placeId)
                        .ToListAsync()

                if photos.Count <> newOrder.Length then
                    return false
                else
                    // Step 1: Assign temporary PhotoNum values (offset by 10000) to avoid unique constraint conflicts
                    for (newNum, oldNum) in newOrder |> List.mapi (fun i oldNum -> (i + 1, oldNum)) do
                        let photo = photos.FirstOrDefault(fun p -> p.PhotoNum = oldNum)
                        if not (isNull photo) then
                            photo.PhotoNum <- 10000 + newNum

                    let! _ = context.SaveChangesAsync()

                    // Step 2: Assign final PhotoNum values
                    for photo in photos do
                        if photo.PhotoNum >= 10000 then
                            photo.PhotoNum <- photo.PhotoNum - 10000

                    let! _ = context.SaveChangesAsync()
                    return true
            finally
                uploadLock.Release() |> ignore
        }

    // Get all photos for a place
    member this.GetPhotosForPlaceAsync(placeId: int) =
        task {
            // Acquire read lock to prevent seeing inconsistent state during reorder
            let uploadLock = getUploadLock(placeId)
            let! _ = uploadLock.WaitAsync()

            try
                let! photos =
                    context.Photos
                        .Where(fun p -> p.PlaceId = placeId)
                        .OrderBy(fun p -> p.PhotoNum :> obj)
                        .ToListAsync()

                return photos |> List.ofSeq
            finally
                uploadLock.Release() |> ignore
        }

    // Delete all photos for a place (used when deleting a place)
    member this.DeleteAllPhotosForPlaceAsync(placeId: int) =
        task {
            // Acquire lock to prevent race condition with concurrent uploads
            let uploadLock = getUploadLock(placeId)
            let! _ = uploadLock.WaitAsync()

            try
                match pathValidation.DeleteDirectorySafely(placeId) with
                | Ok _ -> return ()
                | Error msg ->
                    printfn "Failed to delete photos directory: %s" msg
                    return ()
            finally
                uploadLock.Release() |> ignore
        }

    // Atomic deletion of place with all photos - prevents race conditions
    // This method holds the lock during the entire deletion process
    member this.DeletePlaceWithPhotosAsync(placeId: int, deletePlaceFunc: int -> Task<bool>) =
        task {
            // Acquire lock to prevent race condition with concurrent uploads
            let uploadLock = getUploadLock(placeId)
            let! _ = uploadLock.WaitAsync()

            try
                // Delete photos directory first
                match pathValidation.DeleteDirectorySafely(placeId) with
                | Ok _ -> ()
                | Error msg ->
                    printfn "Failed to delete photos directory: %s" msg

                // Delete place from database (while still holding the lock)
                let! success = deletePlaceFunc(placeId)
                return success
            finally
                uploadLock.Release() |> ignore
        }

    // Set a photo as favorite (and unset others for the same place)
    member this.SetFavoriteAsync(placeId: int, photoNum: int, isFavorite: bool) =
        task {
            // Acquire lock to prevent race conditions (though less critical for this operation)
            let uploadLock = getUploadLock(placeId)
            let! _ = uploadLock.WaitAsync()

            try
                let! photo =
                    context.Photos.FirstOrDefaultAsync(fun p -> p.PlaceId = placeId && p.PhotoNum = photoNum)

                if isNull photo then
                    return false
                else
                    // If setting as favorite, unset all other favorites for this place
                    if isFavorite then
                        let! otherPhotos =
                            context.Photos
                                .Where(fun p -> p.PlaceId = placeId && p.PhotoNum <> photoNum)
                                .ToListAsync()

                        for otherPhoto in otherPhotos do
                            otherPhoto.IsFavorite <- false

                    photo.IsFavorite <- isFavorite
                    let! _ = context.SaveChangesAsync()
                    return true
            finally
                uploadLock.Release() |> ignore
        }

    // Get favorite photo for a place
    member this.GetFavoritePhotoAsync(placeId: int) =
        task {
            // Acquire read lock to prevent seeing inconsistent state
            let uploadLock = getUploadLock(placeId)
            let! _ = uploadLock.WaitAsync()

            try
                let! favoritePhoto =
                    context.Photos
                        .Where(fun p -> p.PlaceId = placeId && p.IsFavorite)
                        .OrderBy(fun p -> p.PhotoNum :> obj)
                        .FirstOrDefaultAsync()

                if isNull favoritePhoto then
                    // Return first photo as fallback
                    let! firstPhoto =
                        context.Photos
                            .Where(fun p -> p.PlaceId = placeId)
                            .OrderBy(fun p -> p.PhotoNum :> obj)
                            .FirstOrDefaultAsync()

                    return if isNull firstPhoto then None else Some(firstPhoto.PhotoNum)
                else
                    return Some(favoritePhoto.PhotoNum)
            finally
                uploadLock.Release() |> ignore
        }
