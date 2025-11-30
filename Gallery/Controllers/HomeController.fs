namespace Gallery.Controllers

open System.Diagnostics
open Microsoft.AspNetCore.Mvc
open Microsoft.Extensions.Logging
open Gallery.Models
open Gallery.Services

type HomeController(logger: ILogger<HomeController>, placeService: PlaceService) =
    inherit Controller()

    [<Route("")>]
    [<ResponseCache(Duration = 30, Location = ResponseCacheLocation.Any)>]
    member this.Index () =
        task {
            let! places = placeService.GetAllPlacesAsync()
            return this.View(places) :> IActionResult
        }

    [<Route("error")>]
    member this.Error () =
        let reqId =
            if isNull Activity.Current then
                this.HttpContext.TraceIdentifier
            else
                Activity.Current.Id
        this.View({ RequestId = reqId })

    [<Route("404")>]
    member this.NotFound () =
        this.HttpContext.Response.StatusCode <- 404
        this.View("NotFound")
