namespace Gallery.Controllers

open System
open Microsoft.AspNetCore.Mvc
open Gallery.Models

// RENAMED: RollController -> PlaceController
type PlaceController() =
    inherit Controller()

    // ---------------------------------------------------------
    // URL: /places/{id}
    // Example: http://localhost:5059/places/1
    // ---------------------------------------------------------
    [<Route("places/{id}")>]
    member this.Index (id: int) =
        
        // Mocking the photos logic
        let photos = 
            [1..33] 
            |> List.map (fun i -> 
                { Num = i; IsPortrait = (i % 3 = 0 || i % 5 = 0) }
            )

        let model = {
            PlaceId = id
            Name = "Old Town Jakarta"
            Location = "Kota Tua"
            Country = "Indonesia"
            TotalPhotos = 33
            Favorites = 4
            Date = "02 Nov, 2025"
            Photos = photos
        }

        this.View(model)
        
    // ---------------------------------------------------------
    // URL: /places/{placeId}/photos/{photoNum}
    // Example: http://localhost:5059/places/1/photos/5
    // ---------------------------------------------------------
    [<Route("places/{placeId}/photos/{photoNum}")>]
    member this.Detail (placeId: int, photoNum: int) =
        
        let totalPhotos = 33
        
        let prevOpt = if photoNum > 1 then Some(photoNum - 1) else None
        let nextOpt = if photoNum < totalPhotos then Some(photoNum + 1) else None

        let uniqueId = sprintf "PH/%X" (photoNum * 12345)

        let model = {
            PlaceId = placeId
            PhotoNum = photoNum
            TotalPhotos = totalPhotos
            PlaceName = "Old Town Jakarta"
            Location = "Kota Tua"
            Country = "Indonesia"
            UniqueId = uniqueId
            PrevPhoto = Option.toNullable prevOpt
            NextPhoto = Option.toNullable nextOpt
        }

        this.View(model)