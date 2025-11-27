namespace Gallery.Services

open System
open System.IO
open System.Linq
open System.Threading.Tasks
open Microsoft.AspNetCore.Http
open Microsoft.EntityFrameworkCore
open Gallery.Data
open Gallery.Models

type PhotoService(context: GalleryDbContext, webHostEnvironment: Microsoft.AspNetCore.Hosting.IWebHostEnvironment) =

    let getPhotoDirectory(placeId: int) =
        let photosPath = Path.Combine(webHostEnvironment.WebRootPath, "images", "places", placeId.ToString())
        if not (Directory.Exists(photosPath)) then
            Directory.CreateDirectory(photosPath) |> ignore
        photosPath

    // Upload photos for a place
    member this.UploadPhotosAsync(placeId: int, files: IFormFile list) =
        task {
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

                        // Determine if portrait based on image dimensions (simplified - check file extension for now)
                        let isPortrait = false // TODO: Implement actual image dimension check

                        let photo = Photo()
                        photo.PlaceId <- placeId
                        photo.PhotoNum <- photoNum
                        photo.IsPortrait <- isPortrait
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
                // Delete file from filesystem
                let photosDir = getPhotoDirectory(placeId)
                let filePath = Path.Combine(photosDir, photo.FileName)

                if File.Exists(filePath) then
                    File.Delete(filePath)

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

                    // Rename file
                    let oldPath = Path.Combine(photosDir, remainingPhoto.FileName)
                    let newFileName = sprintf "%d%s" newNum (Path.GetExtension(remainingPhoto.FileName))
                    let newPath = Path.Combine(photosDir, newFileName)

                    if File.Exists(oldPath) then
                        File.Move(oldPath, newPath)

                    remainingPhoto.PhotoNum <- newNum
                    remainingPhoto.FileName <- newFileName

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
                        let oldPath = Path.Combine(photosDir, photo.FileName)
                        let extension = Path.GetExtension(photo.FileName)
                        let tempPath = Path.Combine(photosDir, sprintf "temp_%d%s" newNum extension)

                        if File.Exists(oldPath) then
                            File.Move(oldPath, tempPath)

                        tempFiles.Add((tempPath, newNum, extension))

                // Rename temp files to final names
                for (tempPath, newNum, extension) in tempFiles do
                    let finalFileName = sprintf "%d%s" newNum extension
                    let finalPath = Path.Combine(photosDir, finalFileName)

                    if File.Exists(tempPath) then
                        File.Move(tempPath, finalPath)

                    let photo = photos.FirstOrDefault(fun p -> p.FileName.Contains(sprintf "temp_%d" newNum))
                    if not (isNull photo) then
                        photo.PhotoNum <- newNum
                        photo.FileName <- finalFileName

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
            let photosDir = getPhotoDirectory(placeId)

            if Directory.Exists(photosDir) then
                Directory.Delete(photosDir, true)

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
