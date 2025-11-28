namespace Gallery.Controllers

open System
open System.Security.Claims
open System.Threading.Tasks
open Microsoft.AspNetCore.Authentication
open Microsoft.AspNetCore.Authentication.Cookies
open Microsoft.AspNetCore.Authorization
open Microsoft.AspNetCore.Mvc
open Microsoft.Extensions.Configuration
open Gallery.Models
open Gallery.Services

type AdminController(placeService: PlaceService, photoService: PhotoService, authService: AuthenticationService, pathValidation: PathValidationService, configuration: IConfiguration) =
    inherit Controller()

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
    member this.Create(model: PlaceFormViewModel) =
        if not this.ModelState.IsValid then
            this.View(model) :> IActionResult
        else
            let endDateOpt =
                if System.String.IsNullOrWhiteSpace(model.EndDate) then None
                else Some(model.EndDate)

            let placeId = placeService.CreatePlaceAsync(model.Name, model.Location, model.Country, model.StartDate, endDateOpt).Result
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
    member this.Login(model: LoginViewModel, returnUrl: string, totpCode: string) =
        task {
            if this.ModelState.IsValid then
                let authMode = configuration.["Authentication:Mode"]

                if authMode = "OIDC" then
                    // OIDC handled by middleware, shouldn't reach here
                    return this.RedirectToAction("Index") :> IActionResult
                else
                    // Local authentication with TOTP
                    let totpCodeOpt = if String.IsNullOrWhiteSpace(totpCode) then None else Some(totpCode)
                    let! authResult = authService.AuthenticateAsync(model.Username, model.Password, totpCodeOpt)

                    match authResult with
                    | Ok user ->
                        let claims =
                            [ Claim(ClaimTypes.Name, user.Username)
                              Claim(ClaimTypes.NameIdentifier, user.Id.ToString())
                              Claim(ClaimTypes.Role, "Admin") ]

                        let claimsIdentity = new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme)
                        let authProperties = AuthenticationProperties()

                        // Configure persistent cookie if "Remember Me" is checked
                        if model.RememberMe then
                            authProperties.IsPersistent <- true
                            authProperties.ExpiresUtc <- Nullable(DateTimeOffset.UtcNow.AddDays(30))

                        do! this.HttpContext.SignInAsync(
                            CookieAuthenticationDefaults.AuthenticationScheme,
                            new ClaimsPrincipal(claimsIdentity),
                            authProperties
                        )

                        // Redirect to return URL or dashboard
                        if not (String.IsNullOrEmpty(returnUrl)) && this.Url.IsLocalUrl(returnUrl) then
                            return this.Redirect(returnUrl) :> IActionResult
                        else
                            return this.RedirectToAction("Index") :> IActionResult
                    | Error msg ->
                        this.ModelState.AddModelError("", msg)
                        return this.View(model) :> IActionResult
            else
                return this.View(model) :> IActionResult
        }

    // GET: /admin/edit/{slug}
    [<Route("/admin/edit/{slug}")>]
    [<Authorize>]
    member this.Edit(slug: string) =
        let placeDetailOpt = placeService.GetPlaceBySlugAsync(slug).Result
        match placeDetailOpt with
        | Some placeDetail ->
            // Convert PlaceDetailPage to PlaceSummary for the view
            let place = {
                Id = placeDetail.PlaceId
                Slug = placeDetail.PlaceSlug
                Name = placeDetail.Name
                Location = placeDetail.Location
                Country = placeDetail.Country
                Photos = placeDetail.TotalPhotos
                TripDates = placeDetail.TripDates
                FavoritePhotoNum = placeDetail.Photos |> List.tryFind (fun p -> p.IsFavorite) |> Option.map (fun p -> p.Num)
                FavoritePhotoFileName = placeDetail.Photos |> List.tryFind (fun p -> p.IsFavorite) |> Option.map (fun p -> p.FileName)
            }
            this.View(place) :> IActionResult
        | None -> this.NotFound() :> IActionResult

    // POST: /admin/update
    [<Route("/admin/update")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.Update(id: int, model: PlaceFormViewModel) =
        if not this.ModelState.IsValid then
            let placeDetailOpt = placeService.GetPlaceByIdAsync(id).Result
            match placeDetailOpt with
            | Some placeDetail ->
                let place = {
                    Id = placeDetail.PlaceId
                    Slug = placeDetail.PlaceSlug
                    Name = placeDetail.Name
                    Location = placeDetail.Location
                    Country = placeDetail.Country
                    Photos = placeDetail.TotalPhotos
                    TripDates = placeDetail.TripDates
                    FavoritePhotoNum = placeDetail.Photos |> List.tryFind (fun p -> p.IsFavorite) |> Option.map (fun p -> p.Num)
                    FavoritePhotoFileName = placeDetail.Photos |> List.tryFind (fun p -> p.IsFavorite) |> Option.map (fun p -> p.FileName)
                }
                this.View("Edit", place) :> IActionResult
            | None -> this.NotFound() :> IActionResult
        else
            let endDateOpt =
                if System.String.IsNullOrWhiteSpace(model.EndDate) then None
                else Some(model.EndDate)

            let success = placeService.UpdatePlaceAsync(id, model.Name, model.Location, model.Country, model.StartDate, endDateOpt).Result
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
        task {
            // Use atomic deletion to prevent race conditions
            // This holds the lock during the entire deletion process
            let! success = photoService.DeletePlaceWithPhotosAsync(id, placeService.DeletePlaceAsync)
            return this.RedirectToAction("Index") :> IActionResult
        }

    // GET: /admin/photos/{slug}
    [<Route("/admin/photos/{slug}")>]
    [<Authorize>]
    member this.Photos(slug: string) =
        match placeService.GetPlaceBySlugAsync(slug).Result with
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

    // GET: /admin/totp-setup
    [<Route("/admin/totp-setup")>]
    [<Authorize>]
    member this.TotpSetup() =
        task {
            let username = this.User.Identity.Name
            let! result = authService.EnableTotpAsync(username)

            match result with
            | Ok secret ->
                let qrCodeBytes = authService.GenerateTotpQrCode(username, secret, "Gallery Admin")
                let qrCodeBase64 = Convert.ToBase64String(qrCodeBytes)
                this.ViewData.["TotpSecret"] <- secret
                return this.View(qrCodeBase64) :> IActionResult
            | Error msg ->
                this.TempData.["Error"] <- msg
                return this.RedirectToAction("Index") :> IActionResult
        }

    // POST: /admin/verify-totp
    [<Route("/admin/verify-totp")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.VerifyTotp(code: string) =
        task {
            let username = this.User.Identity.Name
            let! userOpt = authService.GetAdminUserAsync(username)

            match userOpt with
            | Some user when not (String.IsNullOrEmpty(user.TotpSecret)) ->
                if authService.VerifyTotpCode(user.TotpSecret, code) then
                    this.TempData.["Success"] <- "Two-factor authentication enabled successfully!"
                    return this.RedirectToAction("Index") :> IActionResult
                else
                    this.TempData.["Error"] <- "Invalid code. Please try again."
                    return this.RedirectToAction("TotpSetup") :> IActionResult
            | _ ->
                this.TempData.["Error"] <- "TOTP setup not found."
                return this.RedirectToAction("Index") :> IActionResult
        }

    // POST: /admin/disable-totp
    [<Route("/admin/disable-totp")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.DisableTotp() =
        task {
            let username = this.User.Identity.Name
            let! success = authService.DisableTotpAsync(username)

            if success then
                this.TempData.["Success"] <- "Two-factor authentication disabled."
            else
                this.TempData.["Error"] <- "Failed to disable two-factor authentication."

            return this.RedirectToAction("Index") :> IActionResult
        }

    // POST: /admin/logout
    [<Route("/admin/logout")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.Logout() =
        this.HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme) |> ignore
        this.RedirectToAction("Login") :> IActionResult
