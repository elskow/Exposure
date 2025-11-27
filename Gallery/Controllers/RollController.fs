namespace Gallery.Controllers

open System
open Microsoft.AspNetCore.Mvc
open Gallery.Models

type RollController() =
    inherit Controller()

    // ---------------------------------------------------------
    // URL: /rolls/{id}
    // Example: http://localhost:5059/rolls/1
    // ---------------------------------------------------------
    [<Route("rolls/{id}")>]
    member this.Index (id: int) =
        
        // Mocking the frames logic
        let frames = 
            [1..33] 
            |> List.map (fun i -> 
                { Num = i; IsPortrait = (i % 3 = 0 || i % 5 = 0) }
            )

        let model = {
            RollId = id
            Film = "Kodak Aerocolor IV"
            Camera = "Leica M6"
            Lens = "Leica 35 Summicron-M V4"
            TotalFrames = 33
            Keepers = 4
            Date = "02 Nov, 2025"
            Frames = frames
        }

        this.View(model)
        
    // ---------------------------------------------------------
    // URL: /rolls/{rollId}/frames/{frameNum}
    // Example: http://localhost:5059/rolls/1/frames/5
    // ---------------------------------------------------------
    [<Route("rolls/{rollId}/frames/{frameNum}")>]
    member this.Detail (rollId: int, frameNum: int) =
        
        let totalFrames = 33
        
        // Navigation Logic
        let prevOpt = if frameNum > 1 then Some(frameNum - 1) else None
        let nextOpt = if frameNum < totalFrames then Some(frameNum + 1) else None

        let uniqueId = sprintf "FR/%X" (frameNum * 12345)

        let model = {
            RollId = rollId
            FrameNum = frameNum
            TotalFrames = totalFrames
            Film = "Kodak Aerocolor IV"
            Iso = 100
            Format = "135"
            Process = "C41"
            UniqueId = uniqueId
            // Ensure you are using Nullable<int> in your Model definition as discussed before
            PrevFrame = Option.toNullable prevOpt
            NextFrame = Option.toNullable nextOpt
        }

        this.View(model)