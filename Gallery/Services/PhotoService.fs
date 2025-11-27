namespace Gallery.Services

open System
open System.IO
open System.Linq
open System.Threading.Tasks
open Microsoft.AspNetCore.Http
open Microsoft.EntityFrameworkCore
open Gallery.Data
open Gallery.Models

type PhotoService(context: GalleryDbContext, webHostEnvironment: Microsoft.AspNetCore.Hosting.IWebHostEnvironment, fileValidation: FileValidationService, pathValidation: PathValidationService, malwareScanning: MalwareScanningService) =

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
                    let! place = context.Places.Include(fun p -> p.Photos :> obj).FirstOrDefaultAsync(fun p -> p.Id = placeId)

                    if isNull place then
                        return Error "Place not found"
                    else
                        let photosDir = getPhotoDirectory(placeId)
                        let mutable uploadedCount = 0
                        let currentMaxNum =
                            if place.Photos.Any() then
                                place.Photos.Max(fun p -> p.PhotoNum)
                            else
                                0

                        for (index, file) in files |> List.mapi (fun i f -> (i, f)) do
                            if file.Length > 0L then
                                let photoNum = currentMaxNum + index + 1
                                let extension = Path.GetExtension(file.FileName).ToLowerInvariant()
                                // Normalize extension to .jpg if it's .jpeg
                                let normalizedExtension = if extension = ".jpeg" then ".jpg" else extension
                                let fileName = sprintf "%d%s" photoNum normalizedExtension
                                let filePath = Path.Combine(photosDir, fileName)

                                use stream = new FileStream(filePath, FileMode.Create)
                                do! file.CopyToAsync(stream)

                                let photo = Photo()
                                photo.PlaceId <- placeId
                                photo.PhotoNum <- photoNum
                                photo.FileName <- fileName
                                photo.CreatedAt <- DateTime.UtcNow

                                context.Photos.Add(photo) |> ignore
                                uploadedCount <- uploadedCount + 1

                        let! _ = context.SaveChangesAsync()
                        return Ok uploadedCount
        }

    // Delete a photo
    member this.DeletePhotoAsync(placeId: int, photoNum: int) =
        task {
            let! photo =
                context.Photos.FirstOrDefaultAsync(fun p -> p.PlaceId = placeId && p.PhotoNum = photoNum)

            if isNull photo then
                return false
            else
                // Delete file from filesystem with path validation
                match pathValidation.GetValidatedExistingPhotoPath(placeId, photoNum, photo.FileName) with
                | Ok filePath ->
                    if File.Exists(filePath) then
                        File.Delete(filePath)
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
                    let oldNum = remainingPhoto.PhotoNum
                    let newNum = oldNum - 1
                    let extension = Path.GetExtension(remainingPhoto.FileName)

                    // Rename file with path validation
                    match pathValidation.GetValidatedExistingPhotoPath(placeId, oldNum, remainingPhoto.FileName) with
                    | Ok oldPath ->
                        let newFileName = sprintf "%d%s" newNum extension
                        match pathValidation.GetValidatedPhotoPath(placeId, newNum, extension) with
                        | Ok newPath ->
                            if File.Exists(oldPath) then
                                File.Move(oldPath, newPath)
                            remainingPhoto.PhotoNum <- newNum
                            remainingPhoto.FileName <- newFileName
                        | Error msg ->
                            printfn "Path validation error for new path: %s" msg
                    | Error msg ->
                        printfn "Path validation error for old path: %s" msg

                let! _ = context.SaveChangesAsync()
                return true
        }

    // Reorder photos
    member this.ReorderPhotosAsync(placeId: int, newOrder: int list) =
        task {
            let! photos =
                context.Photos
                    .Where(fun p -> p.PlaceId = placeId)
                    .ToListAsync()

            if photos.Count <> newOrder.Length then
                return false
            else
                let photosDir = getPhotoDirectory(placeId)

                // Create temp mapping
                let tempFiles = ResizeArray<string * int * string>() // (tempPath, newNum, extension)

                for (newNum, oldNum) in newOrder |> List.mapi (fun i oldNum -> (i + 1, oldNum)) do
                    let photo = photos.FirstOrDefault(fun p -> p.PhotoNum = oldNum)

                    if not (isNull photo) then
                        let extension = Path.GetExtension(photo.FileName)

                        match pathValidation.GetValidatedExistingPhotoPath(placeId, oldNum, photo.FileName) with
                        | Ok oldPath ->
                            let tempFileName = sprintf "temp_%d%s" newNum extension
                            match pathValidation.GetValidatedPhotoPath(placeId, 9000 + newNum, extension) with
                            | Ok tempPath ->
                                if File.Exists(oldPath) then
                                    File.Move(oldPath, tempPath)
                                tempFiles.Add((tempPath, newNum, extension))
                            | Error msg ->
                                printfn "Path validation error for temp path: %s" msg
                        | Error msg ->
                            printfn "Path validation error for old path: %s" msg

                // Rename temp files to final names
                for (tempPath, newNum, extension) in tempFiles do
                    let finalFileName = sprintf "%d%s" newNum extension
                    match pathValidation.GetValidatedPhotoPath(placeId, newNum, extension) with
                    | Ok finalPath ->
                        if File.Exists(tempPath) then
                            File.Move(tempPath, finalPath)

                        let photo = photos.FirstOrDefault(fun p -> p.FileName.Contains(sprintf "temp_%d" newNum))
                        if not (isNull photo) then
                            photo.PhotoNum <- newNum
                            photo.FileName <- finalFileName
                    | Error msg ->
                        printfn "Path validation error for final path: %s" msg

                let! _ = context.SaveChangesAsync()
                return true
        }

    // Get all photos for a place
    member this.GetPhotosForPlaceAsync(placeId: int) =
        task {
            let! photos =
                context.Photos
                    .Where(fun p -> p.PlaceId = placeId)
                    .OrderBy(fun p -> p.PhotoNum :> obj)
                    .ToListAsync()

            return photos |> List.ofSeq
        }

    // Delete all photos for a place (used when deleting a place)
    member this.DeleteAllPhotosForPlaceAsync(placeId: int) =
        task {
            match pathValidation.DeleteDirectorySafely(placeId) with
            | Ok _ -> return ()
            | Error msg ->
                printfn "Failed to delete photos directory: %s" msg
                return ()
        }

    // Set a photo as favorite (and unset others for the same place)
    member this.SetFavoriteAsync(placeId: int, photoNum: int, isFavorite: bool) =
        task {
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
        }

    // Get favorite photo for a place
    member this.GetFavoritePhotoAsync(placeId: int) =
        task {
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
        }
