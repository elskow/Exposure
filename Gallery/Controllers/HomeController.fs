namespace Gallery.Controllers

open System
open System.Diagnostics
open Microsoft.AspNetCore.Mvc
open Microsoft.Extensions.Logging
open Gallery.Models
open Gallery.Services

type HomeController(logger: ILogger<HomeController>, dataService: DummyDataService) =
    inherit Controller()

    // 1. Root Route
    [<Route("")>]
    member this.Index () =
        let places = dataService.GetAllPlaces()
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