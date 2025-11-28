namespace Gallery.Controllers

open System
open Microsoft.AspNetCore.Mvc
open Gallery.Models
open Gallery.Services

type PlaceController(placeService: PlaceService) =
    inherit Controller()

    [<Route("places/{slug}")>]
    member this.Index (slug: string) =
        task {
            let! placeDetail = placeService.GetPlaceBySlugAsync(slug)
            match placeDetail with
            | Some detail -> return this.View(detail) :> IActionResult
            | None -> return this.NotFound() :> IActionResult
        }

    [<Route("places/{placeSlug}/photos/{photoSlug}")>]
    member this.Detail (placeSlug: string, photoSlug: string) =
        task {
            let! placeDetailOpt = placeService.GetPlaceBySlugAsync(placeSlug)
            match placeDetailOpt with
            | Some placeDetail ->
                let totalPhotos = placeDetail.TotalPhotos

                let currentPhoto = placeDetail.Photos |> List.tryFind (fun p -> p.Slug = photoSlug)
                match currentPhoto with
                | None -> return this.NotFound() :> IActionResult
                | Some photo ->
                    let prevPhotoOpt =
                        if photo.Num > 1 then
                            placeDetail.Photos |> List.tryFind (fun p -> p.Num = photo.Num - 1)
                        else None
                    let nextPhotoOpt =
                        if photo.Num < totalPhotos then
                            placeDetail.Photos |> List.tryFind (fun p -> p.Num = photo.Num + 1)
                        else None

                    let uniqueId = sprintf "PH/%X" (photo.Num * 12345)

                    let photoModel = {
                        PlaceId = placeDetail.PlaceId
                        PlaceSlug = placeDetail.PlaceSlug
                        PhotoNum = photo.Num
                        PhotoSlug = photo.Slug
                        FileName = photo.FileName
                        TotalPhotos = totalPhotos
                        PlaceName = placeDetail.Name
                        Location = placeDetail.Location
                        Country = placeDetail.Country
                        TripDates = placeDetail.TripDates
                        UniqueId = uniqueId
                        PrevPhoto = prevPhotoOpt |> Option.map (fun p -> p.Num) |> Option.toNullable
                        NextPhoto = nextPhotoOpt |> Option.map (fun p -> p.Num) |> Option.toNullable
                        PrevPhotoSlug = prevPhotoOpt |> Option.map (fun p -> p.Slug)
                        NextPhotoSlug = nextPhotoOpt |> Option.map (fun p -> p.Slug)
                        PrevPhotoFileName = prevPhotoOpt |> Option.map (fun p -> p.FileName)
                        NextPhotoFileName = nextPhotoOpt |> Option.map (fun p -> p.FileName)
                    }
                    return this.View(photoModel) :> IActionResult
            | None -> return this.NotFound() :> IActionResult
        }
