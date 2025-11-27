namespace Gallery.Controllers

open System
open Microsoft.AspNetCore.Mvc
open Gallery.Models
open Gallery.Services

// RENAMED: RollController -> PlaceController
type PlaceController(placeService: PlaceService) =
    inherit Controller()

    // ---------------------------------------------------------
    // URL: /places/{id}
    // Example: http://localhost:5059/places/1
    // ---------------------------------------------------------
    [<Route("places/{id}")>]
    member this.Index (id: int) =
        let placeDetail = placeService.GetPlaceByIdAsync(id).Result
        match placeDetail with
        | Some detail -> this.View(detail) :> IActionResult
        | None -> this.NotFound() :> IActionResult

    // ---------------------------------------------------------
    // URL: /places/{placeId}/photos/{photoNum}
    // Example: http://localhost:5059/places/1/photos/5
    // ---------------------------------------------------------
    [<Route("places/{placeId}/photos/{photoNum}")>]
    member this.Detail (placeId: int, photoNum: int) =
        let placeDetailOpt = placeService.GetPlaceByIdAsync(placeId).Result
        match placeDetailOpt with
        | Some placeDetail ->
            let totalPhotos = placeDetail.TotalPhotos
            let prevOpt = if photoNum > 1 then Some(photoNum - 1) else None
            let nextOpt = if photoNum < totalPhotos then Some(photoNum + 1) else None
            let uniqueId = sprintf "PH/%X" (photoNum * 12345)

            let photoModel = {
                PlaceId = placeId
                PhotoNum = photoNum
                TotalPhotos = totalPhotos
                PlaceName = placeDetail.Name
                Location = placeDetail.Location
                Country = placeDetail.Country
                TripDates = placeDetail.TripDates
                UniqueId = uniqueId
                PrevPhoto = Option.toNullable prevOpt
                NextPhoto = Option.toNullable nextOpt
            }
            this.View(photoModel) :> IActionResult
        | None -> this.NotFound() :> IActionResult
