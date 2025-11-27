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

type AdminController(dataService: DummyDataService) =
    inherit Controller()

    // Simple admin credentials (in production, use proper password hashing)
    let adminUsername = "admin"
    let adminPassword = "admin123"

    // GET: /admin
    [<Route("/admin")>]
    [<Authorize>]
    member this.Index() =
        let places = dataService.GetAllPlaces()
        let totalPhotos = places |> List.sumBy (fun p -> p.Photos)

        // Calculate total favorites from dummy data
        let totalFavorites =
            places
            |> List.choose (fun place -> dataService.GetPlaceById(place.Id))
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
    member this.Create(model: NewEntryViewModel) =
        // For now, just redirect to the dashboard
        this.RedirectToAction("Index") :> IActionResult

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
        match dataService.GetAllPlaces() |> List.tryFind (fun p -> p.Id = id) with
        | Some place -> this.View(place) :> IActionResult
        | None -> this.NotFound() :> IActionResult

    // POST: /admin/update
    [<Route("/admin/update")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.Update(model: PlaceSummary) =
        // For now with dummy data, just redirect back to dashboard
        // In real implementation, this would update the database
        this.RedirectToAction("Index") :> IActionResult

    // POST: /admin/delete
    [<Route("/admin/delete")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.Delete(id: int) =
        // For now with dummy data, just redirect back to dashboard
        // In real implementation, this would delete from the database
        this.RedirectToAction("Index") :> IActionResult

    // GET: /admin/photos/{id}
    [<Route("/admin/photos/{id}")>]
    [<Authorize>]
    member this.Photos(id: int) =
        match dataService.GetPlaceById(id) with
        | Some placeDetail -> this.View(placeDetail) :> IActionResult
        | None -> this.NotFound() :> IActionResult

    // POST: /admin/logout
    [<Route("/admin/logout")>]
    [<HttpPost>]
    [<Authorize>]
    [<ValidateAntiForgeryToken>]
    member this.Logout() =
        this.HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme) |> ignore
        this.RedirectToAction("Login") :> IActionResult
