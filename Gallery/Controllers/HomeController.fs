namespace Gallery.Controllers

open System
open System.Diagnostics
open Microsoft.AspNetCore.Mvc
open Microsoft.Extensions.Logging
open Gallery.Models
open Gallery.Services

type HomeController(logger: ILogger<HomeController>, placeService: PlaceService) =
    inherit Controller()

    // 1. Root Route
    [<Route("")>]
    member this.Index () =
        let places = placeService.GetAllPlacesAsync().Result
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

    [<Route("404")>]
    [<ResponseCache(Duration = 0, Location = ResponseCacheLocation.None, NoStore = true)>]
    member this.NotFound () =
        this.HttpContext.Response.StatusCode <- 404
        this.View("NotFound")
