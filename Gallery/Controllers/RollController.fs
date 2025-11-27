namespace Gallery.Controllers

open System
open Microsoft.AspNetCore.Mvc
open Gallery.Models

type RollController() =
    inherit Controller()

    // Route: /Roll/Index/{id}
    member this.Index (id: int) =
        
        // Logic to generate the 33 frames mock data
        // Alternates portrait/landscape to mimic the layout
        let frames = 
            [1..33] 
            |> List.map (fun i -> 
                { Num = i; IsPortrait = (i % 3 = 0 || i % 5 = 0) }
            )

        // Create the model for the specific roll
        // In a real app, you would fetch this from a DB using the 'id'
        let model = {
            RollId = id
            Film = "Kodak Aerocolor IV" // You can make this dynamic based on ID later
            Camera = "Leica M6"
            Lens = "Leica 35 Summicron-M V4"
            TotalFrames = 33
            Keepers = 4
            Date = "02 Nov, 2025"
            Frames = frames
        }

        this.View(model)