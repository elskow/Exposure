namespace Gallery.Models

open System.ComponentModel.DataAnnotations

type LoginViewModel() =
    [<Required(ErrorMessage = "Username is required")>]
    member val Username = "" with get, set

    [<Required(ErrorMessage = "Password is required")>]
    [<DataType(DataType.Password)>]
    member val Password = "" with get, set

    member val RememberMe = false with get, set

type DashboardViewModel = {
    TotalPlaces: int
    TotalPhotos: int
    TotalFavorites: int
    RecentPlaces: PlaceSummary list
}

type NewEntryViewModel() =
    [<Required(ErrorMessage = "Name is required")>]
    member val Name = "" with get, set

    [<Required(ErrorMessage = "Location is required")>]
    member val Location = "" with get, set

    [<Required(ErrorMessage = "Country is required")>]
    member val Country = "" with get, set

    [<Required(ErrorMessage = "Trip dates are required")>]
    member val TripDates = "" with get, set

    member val Description = "" with get, set
