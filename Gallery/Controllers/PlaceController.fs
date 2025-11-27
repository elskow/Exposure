namespace Gallery.Controllers

open System
open Microsoft.AspNetCore.Mvc
open Gallery.Models
open Gallery.Services

// RENAMED: RollController -> PlaceController
type PlaceController(dataService: DummyDataService) =
    inherit Controller()

    // ---------------------------------------------------------
    // URL: /places/{id}
    // Example: http://localhost:5059/places/1
    // ---------------------------------------------------------
    [<Route("places/{id}")>]
    member this.Index (id: int) =
        match dataService.GetPlaceById(id) with
        | Some placeDetail -> this.View(placeDetail) :> IActionResult
        | None -> this.NotFound() :> IActionResult

    // ---------------------------------------------------------
    // URL: /places/{placeId}/photos/{photoNum}
    // Example: http://localhost:5059/places/1/photos/5
    // ---------------------------------------------------------
    [<Route("places/{placeId}/photos/{photoNum}")>]
    member this.Detail (placeId: int, photoNum: int) =
        match dataService.GetPhotoViewModel(placeId, photoNum) with
        | Some photoModel -> this.View(photoModel) :> IActionResult
        | None -> this.NotFound() :> IActionResult