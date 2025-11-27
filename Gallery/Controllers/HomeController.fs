namespace Gallery.Controllers

open System
open System.Diagnostics
open Microsoft.AspNetCore.Mvc
open Microsoft.Extensions.Logging
open Gallery.Models

type HomeController(logger: ILogger<HomeController>) =
    inherit Controller()

    member this.Index () =
        // Mock Data: This replaces the C# code block in your Index.cshtml
        let rolls = [
            { Id = 1; Film = "Classic Chrome"; Camera = "Fujifilm X-A10"; Lens = "56mm f/1.2"; Frames = 24; Date = "OCT 25" }
            { Id = 2; Film = "Acros+R Filter"; Camera = "Fujifilm X-A10"; Lens = "56mm f/1.2"; Frames = 12; Date = "NOV 25" }
            { Id = 3; Film = "Provia Standard"; Camera = "Fujifilm X-A10"; Lens = "XC 16-50mm"; Frames = 45; Date = "NOV 25" }
            { Id = 4; Film = "Kodak Portra 400"; Camera = "Analog SLR"; Lens = "50mm f/1.8"; Frames = 36; Date = "SEP 25" }
            { Id = 5; Film = "Godox Flash Test"; Camera = "Fujifilm X-A10"; Lens = "56mm f/1.2"; Frames = 8; Date = "AUG 25" }
            { Id = 6; Film = "Velvia 50"; Camera = "Fujifilm X-A10"; Lens = "Manual Focus"; Frames = 19; Date = "JUL 25" }
        ]
        
        // Pass the list to the View
        this.View(rolls)

    [<ResponseCache(Duration = 0, Location = ResponseCacheLocation.None, NoStore = true)>]
    member this.Error () =
        let reqId =
            if isNull Activity.Current then
                this.HttpContext.TraceIdentifier
            else
                Activity.Current.Id

        this.View({ RequestId = reqId })