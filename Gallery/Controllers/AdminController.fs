namespace Gallery.Controllers

open System
open System.Security.Claims
open System.Threading.Tasks
open Microsoft.AspNetCore.Authentication
open Microsoft.AspNetCore.Authentication.Cookies
open Microsoft.AspNetCore.Authorization
open Microsoft.AspNetCore.Mvc
open Gallery.Models
open Gallery.Services

type AdminController(placeService: PlaceService, photoService: PhotoService) =
    inherit Controller()

    // Simple admin credentials (in production, use proper password hashing)
    let adminUsername = "admin"
    let adminPassword = "admin123"

    // GET: /admin
    [<Route("/admin")>]
    [<Authorize>]
    member this.Index() =
        let places = placeService.GetAllPlacesAsync().Result
        let totalPhotos = places |> List.sumBy (fun p -> p.Photos)

        // Calculate total favorites from database
        let totalFavorites =
            places
            |> List.choose (fun place -> placeService.GetPlaceByIdAsync(place.Id).Result)
            |> List.sumBy (fun placeDetail -> placeDetail.Favorites)

        let model = {
            TotalPlaces = List.length places
            TotalPhotos = totalPhotos
            TotalFavorites = totalFavorites
            RecentPlaces = places
        }

        this.View(model)

    // GET: /admin/create
    [<Route("/admin/create")>]
    [<Authorize>]
    member this.Create() =
        this.View()

    // POST: /admin/create
    [<Route("/admin/create")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.Create(name: string, location: string, country: string, startDate: string, endDate: string) =
        let endDateOpt =
            if System.String.IsNullOrWhiteSpace(endDate) then None
            else Some(endDate)

        let placeId = placeService.CreatePlaceAsync(name, location, country, startDate, endDateOpt).Result
        this.RedirectToAction("Edit", {| id = placeId |}) :> IActionResult

    // GET: /admin/login
    [<Route("/admin/login")>]
    [<AllowAnonymous>]
    member this.Login(returnUrl: string) =
        // If user is already authenticated, redirect to dashboard
        if this.User.Identity.IsAuthenticated then
            this.RedirectToAction("Index") :> IActionResult
        else
            this.View() :> IActionResult

    // POST: /admin/login
    [<Route("/admin/login")>]
    [<HttpPost>]
    [<AllowAnonymous>]
    [<ValidateAntiForgeryToken>]
    member this.Login(model: LoginViewModel, returnUrl: string) =
        if this.ModelState.IsValid then
            // Simple credential check (in production, use proper password verification)
            if model.Username = adminUsername && model.Password = adminPassword then
                let claims =
                    [ Claim(ClaimTypes.Name, model.Username)
                      Claim(ClaimTypes.Role, "Admin") ]

                let claimsIdentity = new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme)
                let authProperties = AuthenticationProperties()

                // Configure persistent cookie if "Remember Me" is checked
                if model.RememberMe then
                    authProperties.IsPersistent <- true
                    authProperties.ExpiresUtc <- Nullable(DateTimeOffset.UtcNow.AddDays(30))

                let result = this.HttpContext.SignInAsync(
                    CookieAuthenticationDefaults.AuthenticationScheme,
                    new ClaimsPrincipal(claimsIdentity),
                    authProperties
                )

                // Redirect to return URL or dashboard
                if not (String.IsNullOrEmpty(returnUrl)) && this.Url.IsLocalUrl(returnUrl) then
                    this.Redirect(returnUrl) :> IActionResult
                else
                    this.RedirectToAction("Index") :> IActionResult
            else
                this.ModelState.AddModelError("", "Invalid username or password")
                this.View(model) :> IActionResult
        else
            this.View(model) :> IActionResult

    // GET: /admin/edit/{id}
    [<Route("/admin/edit/{id}")>]
    [<Authorize>]
    member this.Edit(id: int) =
        let placeDetailOpt = placeService.GetPlaceByIdAsync(id).Result
        match placeDetailOpt with
        | Some placeDetail ->
            // Convert PlaceDetailPage to PlaceSummary for the view
            let place = {
                Id = placeDetail.PlaceId
                Name = placeDetail.Name
                Location = placeDetail.Location
                Country = placeDetail.Country
                Photos = placeDetail.TotalPhotos
                TripDates = placeDetail.TripDates
                FavoritePhotoNum = placeDetail.Photos |> List.tryFind (fun p -> p.IsFavorite) |> Option.map (fun p -> p.Num)
            }
            this.View(place) :> IActionResult
        | None -> this.NotFound() :> IActionResult

    // POST: /admin/update
    [<Route("/admin/update")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.Update(id: int, name: string, location: string, country: string, startDate: string, endDate: string) =
        let endDateOpt =
            if System.String.IsNullOrWhiteSpace(endDate) then None
            else Some(endDate)

        let success = placeService.UpdatePlaceAsync(id, name, location, country, startDate, endDateOpt).Result
        if success then
            this.RedirectToAction("Index") :> IActionResult
        else
            this.NotFound() :> IActionResult

    // POST: /admin/delete
    [<Route("/admin/delete")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.Delete(id: int) =
        // Delete all photos for this place first
        photoService.DeleteAllPhotosForPlaceAsync(id).Wait()

        // Delete the place from database
        let success = placeService.DeletePlaceAsync(id).Result
        this.RedirectToAction("Index") :> IActionResult

    // GET: /admin/photos/{id}
    [<Route("/admin/photos/{id}")>]
    [<Authorize>]
    member this.Photos(id: int) =
        match placeService.GetPlaceByIdAsync(id).Result with
        | Some placeDetail -> this.View(placeDetail) :> IActionResult
        | None -> this.NotFound() :> IActionResult

    // POST: /admin/photos/upload
    [<Route("/admin/photos/upload")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.UploadPhotos(placeId: int, files: Microsoft.AspNetCore.Http.IFormFileCollection) =
        if isNull files || files.Count = 0 then
            this.BadRequest("No files uploaded") :> IActionResult
        else
            let fileList = files |> Seq.toList
            let result = photoService.UploadPhotosAsync(placeId, fileList).Result

            match result with
            | Ok count ->
                this.Json({| success = true; message = sprintf "Uploaded %d photo(s)" count; count = count |}) :> IActionResult
            | Error msg ->
                this.BadRequest({| success = false; message = msg |}) :> IActionResult

    // POST: /admin/photos/delete
    [<Route("/admin/photos/delete")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.DeletePhoto(placeId: int, photoNum: int) =
        let success = photoService.DeletePhotoAsync(placeId, photoNum).Result
        if success then
            this.Json({| success = true; message = "Photo deleted successfully" |}) :> IActionResult
        else
            this.NotFound({| success = false; message = "Photo not found" |}) :> IActionResult

    // POST: /admin/photos/reorder
    [<Route("/admin/photos/reorder")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.ReorderPhotos(placeId: int, order: int[]) =
        let orderList = order |> Array.toList
        let success = photoService.ReorderPhotosAsync(placeId, orderList).Result
        if success then
            this.Json({| success = true; message = "Photos reordered successfully" |}) :> IActionResult
        else
            this.BadRequest({| success = false; message = "Failed to reorder photos" |}) :> IActionResult

    // POST: /admin/photos/favorite
    [<Route("/admin/photos/favorite")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.SetFavorite(placeId: int, photoNum: int, isFavorite: bool) =
        let success = photoService.SetFavoriteAsync(placeId, photoNum, isFavorite).Result
        if success then
            this.Json({| success = true; message = (if isFavorite then "Photo set as favorite" else "Favorite removed") |}) :> IActionResult
        else
            this.NotFound({| success = false; message = "Photo not found" |}) :> IActionResult

    // POST: /admin/logout
    [<Route("/admin/logout")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.Logout() =
        this.HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme) |> ignore
        this.RedirectToAction("Login") :> IActionResult
