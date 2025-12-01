namespace Gallery.Controllers

open System
open System.Security.Claims
open System.Threading.Tasks
open Microsoft.AspNetCore.Authentication
open Microsoft.AspNetCore.Authentication.Cookies
open Microsoft.AspNetCore.Authentication.OpenIdConnect
open Microsoft.AspNetCore.Authorization
open Microsoft.AspNetCore.Mvc
open Microsoft.Extensions.Configuration
open Gallery.Models
open Gallery.Services
open Microsoft.Extensions.Logging

type AdminController(placeService: PlaceService, photoService: PhotoService, authService: AuthenticationService, pathValidation: PathValidationService, inputValidation: InputValidationService, configuration: IConfiguration, logger: ILogger<AdminController>) =
    inherit Controller()

    let toPlaceSummary (placeDetail: PlaceDetailPage) =
        {
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

    [<Route("/admin")>]
    [<Authorize>]
    member this.Index() =
        task {
            let! places = placeService.GetAllPlacesAsync()
            let totalPhotos = places |> List.sumBy (fun p -> p.Photos)
            let! totalFavorites = placeService.GetTotalFavoritesAsync()

            let model = {
                TotalPlaces = List.length places
                TotalPhotos = totalPhotos
                TotalFavorites = totalFavorites
                RecentPlaces = places
            }

            return this.View(model) :> IActionResult
        }

    [<Route("/admin/create")>]
    [<Authorize>]
    member this.Create() =
        this.View()

    [<Route("/admin/create")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.Create(model: PlaceFormViewModel) =
        task {
            if not this.ModelState.IsValid then
                return this.View(model) :> IActionResult
            else
                let validationResult = inputValidation.ValidatePlaceForm(model.Name, model.Location, model.Country, model.StartDate, model.EndDate |> Option.ofObj |> Option.defaultValue "")

                match validationResult with
                | Error errors ->
                    errors |> List.iter (fun err -> this.ModelState.AddModelError("", err))
                    return this.View(model) :> IActionResult
                | Ok (validName, validLocation, validCountry, validStartDate, validEndDate) ->
                    let! slug = placeService.CreatePlaceAsync(validName, validLocation, validCountry, validStartDate, validEndDate)
                    return this.RedirectToAction("Edit", {| slug = slug |}) :> IActionResult
        }

    [<Route("/admin/login")>]
    [<AllowAnonymous>]
    member this.Login(returnUrl: string) =
        if this.User.Identity.IsAuthenticated then
            this.RedirectToAction("Index") :> IActionResult
        else
            let authMode = configuration.["Authentication:Mode"]
            if authMode = "OIDC" then
                let properties = AuthenticationProperties()
                properties.RedirectUri <- if String.IsNullOrEmpty(returnUrl) then "/admin" else returnUrl
                this.Challenge(properties, OpenIdConnectDefaults.AuthenticationScheme) :> IActionResult
            else
                this.View() :> IActionResult

    [<Route("/admin/login")>]
    [<HttpPost>]
    [<AllowAnonymous>]
    [<ValidateAntiForgeryToken>]
    member this.Login(model: LoginViewModel, returnUrl: string, totpCode: string) =
        task {
            if this.ModelState.IsValid then
                let authMode = configuration.["Authentication:Mode"]

                if authMode = "OIDC" then
                    return this.RedirectToAction("Index") :> IActionResult
                else
                    let usernameValidation = inputValidation.ValidateUsername(model.Username)
                    match usernameValidation with
                    | Error msg ->
                        this.ModelState.AddModelError("", "Invalid credentials")
                        return this.View(model) :> IActionResult
                    | Ok validUsername ->
                        let totpCodeOpt =
                            if String.IsNullOrWhiteSpace(totpCode) then
                                None
                            else
                                match inputValidation.ValidateTotpCode(totpCode) with
                                | Ok code -> Some(code)
                                | Error _ -> None

                        let! authResult = authService.AuthenticateAsync(validUsername, model.Password, totpCodeOpt)

                        match authResult with
                        | Ok user ->
                            let claims =
                                [ Claim(ClaimTypes.Name, user.Username)
                                  Claim(ClaimTypes.NameIdentifier, user.Id.ToString())
                                  Claim(ClaimTypes.Role, "Admin") ]

                            let claimsIdentity = new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme)
                            let authProperties = AuthenticationProperties()

                            if model.RememberMe then
                                authProperties.IsPersistent <- true
                                authProperties.ExpiresUtc <- Nullable(DateTimeOffset.UtcNow.AddDays(30))

                            do! this.HttpContext.SignInAsync(
                                CookieAuthenticationDefaults.AuthenticationScheme,
                                new ClaimsPrincipal(claimsIdentity),
                                authProperties
                            )

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

    [<Route("/admin/edit/{slug}")>]
    [<Authorize>]
    member this.Edit(slug: string) =
        task {
            let! placeDetailOpt = placeService.GetPlaceBySlugAsync(slug)
            match placeDetailOpt with
            | Some placeDetail ->
                let place = toPlaceSummary placeDetail
                return this.View(place) :> IActionResult
            | None -> return this.NotFound() :> IActionResult
        }

    [<Route("/admin/update")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.Update(id: int, model: PlaceFormViewModel) =
        task {
            match inputValidation.ValidateId(id, "Place ID") with
            | Error msg ->
                return this.BadRequest(msg) :> IActionResult
            | Ok validId ->
                if not this.ModelState.IsValid then
                    let! placeDetailOpt = placeService.GetPlaceByIdAsync(validId)
                    match placeDetailOpt with
                    | Some placeDetail ->
                        let place = toPlaceSummary placeDetail
                        return this.View("Edit", place) :> IActionResult
                    | None -> return this.NotFound() :> IActionResult
                else
                    let validationResult = inputValidation.ValidatePlaceForm(model.Name, model.Location, model.Country, model.StartDate, model.EndDate |> Option.ofObj |> Option.defaultValue "")

                    match validationResult with
                    | Error errors ->
                        errors |> List.iter (fun err -> this.ModelState.AddModelError("", err))
                        let! placeDetailOpt = placeService.GetPlaceByIdAsync(validId)
                        match placeDetailOpt with
                        | Some placeDetail ->
                            let place = toPlaceSummary placeDetail
                            return this.View("Edit", place) :> IActionResult
                        | None -> return this.NotFound() :> IActionResult
                    | Ok (validName, validLocation, validCountry, validStartDate, validEndDate) ->
                        let! success = placeService.UpdatePlaceAsync(validId, validName, validLocation, validCountry, validStartDate, validEndDate)
                        if success then
                            return this.RedirectToAction("Index") :> IActionResult
                        else
                            return this.NotFound() :> IActionResult
        }

    [<Route("/admin/delete")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.Delete(id: int) =
        task {
            match inputValidation.ValidateId(id, "Place ID") with
            | Error msg ->
                return this.BadRequest({| success = false; message = msg |}) :> IActionResult
            | Ok validId ->
                let! success = photoService.DeletePlaceWithPhotosAsync(validId, placeService.DeletePlaceAsync)
                if success then
                    return this.Json({| success = true; message = "Place deleted successfully" |}) :> IActionResult
                else
                    return this.NotFound({| success = false; message = "Place not found" |}) :> IActionResult
        }

    [<Route("/admin/photos/{slug}")>]
    [<Authorize>]
    member this.Photos(slug: string) =
        task {
            let! placeDetailOpt = placeService.GetPlaceBySlugAsync(slug)
            match placeDetailOpt with
            | Some placeDetail -> return this.View(placeDetail) :> IActionResult
            | None -> return this.NotFound() :> IActionResult
        }

    [<Route("/admin/photos/upload")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.UploadPhotos(placeId: int, files: Microsoft.AspNetCore.Http.IFormFileCollection) =
        task {
            match inputValidation.ValidateId(placeId, "Place ID") with
            | Error msg ->
                return this.BadRequest({| success = false; message = msg |}) :> IActionResult
            | Ok validPlaceId ->
                if isNull files || files.Count = 0 then
                    return this.BadRequest({| success = false; message = "No files uploaded" |}) :> IActionResult
                else
                    let fileList = files |> Seq.toList
                    let! result = photoService.UploadPhotosAsync(validPlaceId, fileList)

                    match result with
                    | Ok count ->
                        return this.Json({| success = true; message = sprintf "Uploaded %d photo(s)" count; count = count |}) :> IActionResult
                    | Error msg ->
                        return this.BadRequest({| success = false; message = msg |}) :> IActionResult
        }

    [<Route("/admin/photos/delete")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.DeletePhoto(placeId: int, photoNum: int) =
        task {
            match inputValidation.ValidateId(placeId, "Place ID"), inputValidation.ValidateId(photoNum, "Photo number") with
            | Error msg, _ -> return this.BadRequest({| success = false; message = msg |}) :> IActionResult
            | _, Error msg -> return this.BadRequest({| success = false; message = msg |}) :> IActionResult
            | Ok validPlaceId, Ok validPhotoNum ->
                let! success = photoService.DeletePhotoAsync(validPlaceId, validPhotoNum)
                if success then
                    return this.Json({| success = true; message = "Photo deleted successfully" |}) :> IActionResult
                else
                    return this.NotFound({| success = false; message = "Photo not found" |}) :> IActionResult
        }

    [<Route("/admin/photos/reorder")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.ReorderPhotos([<FromForm>] placeId: int, [<FromForm>] order: int[]) =
        task {
            let orderArray = if isNull (box order) then [||] else order
            
            match inputValidation.ValidateId(placeId, "Place ID") with
            | Error msg ->
                return this.BadRequest({| success = false; message = msg |}) :> IActionResult
            | Ok validPlaceId ->
                if orderArray.Length = 0 then
                    return this.BadRequest({| success = false; message = "No order provided" |}) :> IActionResult
                else
                    let orderValidations = orderArray |> Array.map (fun o -> inputValidation.ValidateId(o, "Order value"))
                    let invalidOrders = orderValidations |> Array.choose (function Error msg -> Some msg | Ok _ -> None)

                    if invalidOrders.Length > 0 then
                        return this.BadRequest({| success = false; message = invalidOrders.[0] |}) :> IActionResult
                    else
                        let orderList = orderArray |> Array.toList
                        let! success = photoService.ReorderPhotosAsync(validPlaceId, orderList)
                        if success then
                            return this.Json({| success = true; message = "Photos reordered successfully" |}) :> IActionResult
                        else
                            return this.BadRequest({| success = false; message = "Failed to reorder photos" |}) :> IActionResult
        }

    [<Route("/admin/photos/favorite")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.SetFavorite(placeId: int, photoNum: int, isFavorite: bool) =
        task {
            match inputValidation.ValidateId(placeId, "Place ID"), inputValidation.ValidateId(photoNum, "Photo number") with
            | Error msg, _ -> return this.BadRequest({| success = false; message = msg |}) :> IActionResult
            | _, Error msg -> return this.BadRequest({| success = false; message = msg |}) :> IActionResult
            | Ok validPlaceId, Ok validPhotoNum ->
                let! success = photoService.SetFavoriteAsync(validPlaceId, validPhotoNum, isFavorite)
                if success then
                    return this.Json({| success = true; message = (if isFavorite then "Photo set as favorite" else "Favorite removed") |}) :> IActionResult
                else
                    return this.NotFound({| success = false; message = "Photo not found" |}) :> IActionResult
        }

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

    [<Route("/admin/verify-totp")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.VerifyTotp(code: string) =
        task {
            match inputValidation.ValidateTotpCode(code) with
            | Error msg ->
                this.TempData.["Error"] <- msg
                return this.RedirectToAction("TotpSetup") :> IActionResult
            | Ok validCode ->
                let username = this.User.Identity.Name
                let! userOpt = authService.GetAdminUserAsync(username)

                match userOpt with
                | Some user when not (String.IsNullOrEmpty(user.TotpSecret)) ->
                    if authService.VerifyTotpCode(user.TotpSecret, validCode) then
                        this.TempData.["Success"] <- "Two-factor authentication enabled successfully!"
                        return this.RedirectToAction("Index") :> IActionResult
                    else
                        this.TempData.["Error"] <- "Invalid code. Please try again."
                        return this.RedirectToAction("TotpSetup") :> IActionResult
                | _ ->
                    this.TempData.["Error"] <- "TOTP setup not found."
                    return this.RedirectToAction("Index") :> IActionResult
        }

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

    [<Route("/admin/logout")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.Logout() =
        task {
            do! this.HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme)
            return this.Redirect("/admin/login") :> IActionResult
        }
