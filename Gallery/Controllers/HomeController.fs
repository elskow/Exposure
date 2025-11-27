namespace Gallery.Controllers

open System
open System.Diagnostics
open Microsoft.AspNetCore.Mvc
open Microsoft.Extensions.Logging
open Gallery.Models

type HomeController(logger: ILogger<HomeController>) =
    inherit Controller()

    // 1. Root Route
    [<Route("")>]
    member this.Index () =
        let places = [
            { Id = 1; Name = "Old Town Jakarta"; Location = "Kota Tua"; Country = "Indonesia"; Photos = 24; Date = "OCT 25" }
            { Id = 2; Name = "Bali Rice Terraces"; Location = "Tegallalang"; Country = "Indonesia"; Photos = 12; Date = "NOV 25" }
            { Id = 3; Name = "Tokyo Streets"; Location = "Shibuya"; Country = "Japan"; Photos = 45; Date = "NOV 25" }
            { Id = 4; Name = "Parisian Cafés"; Location = "Le Marais"; Country = "France"; Photos = 36; Date = "SEP 25" }
            { Id = 5; Name = "NYC Skyline"; Location = "Brooklyn Bridge"; Country = "USA"; Photos = 8; Date = "AUG 25" }
            { Id = 6; Name = "Icelandic Coast"; Location = "Vík í Mýrdal"; Country = "Iceland"; Photos = 19; Date = "JUL 25" }
        ]
        this.View(places)

    [<Route("error")>]
    [<ResponseCache(Duration = 0, Location = ResponseCacheLocation.None, NoStore = true)>]
    member this.Error () =
        let reqId =
            if isNull Activity.Current then
                this.HttpContext.TraceIdentifier
            else
                Activity.Current.Id
        this.View({ RequestId = reqId })