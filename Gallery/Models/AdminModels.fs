namespace Gallery.Models

open System
open System.ComponentModel.DataAnnotations

type LoginViewModel() =
    [<Required(ErrorMessage = "Username is required")>]
    [<StringLength(100, MinimumLength = 3, ErrorMessage = "Username must be between 3 and 100 characters")>]
    [<RegularExpression(@"^[a-zA-Z0-9_-]+$", ErrorMessage = "Username can only contain letters, numbers, underscores and hyphens")>]
    member val Username = "" with get, set

    [<Required(ErrorMessage = "Password is required")>]
    [<StringLength(100, MinimumLength = 8, ErrorMessage = "Password must be at least 8 characters")>]
    [<DataType(DataType.Password)>]
    member val Password = "" with get, set

    member val RememberMe = false with get, set

type DashboardViewModel = {
    TotalPlaces: int
    TotalPhotos: int
    TotalFavorites: int
    RecentPlaces: PlaceSummary list
}

type PlaceFormViewModel() =
    [<Required(ErrorMessage = "Name is required")>]
    [<StringLength(200, MinimumLength = 1, ErrorMessage = "Name must be between 1 and 200 characters")>]
    [<RegularExpression(@"^[^<>{}\\]+$", ErrorMessage = "Name contains invalid characters")>]
    member val Name = "" with get, set

    [<Required(ErrorMessage = "Location is required")>]
    [<StringLength(100, MinimumLength = 1, ErrorMessage = "Location must be between 1 and 100 characters")>]
    [<RegularExpression(@"^[^<>{}\\]+$", ErrorMessage = "Location contains invalid characters")>]
    member val Location = "" with get, set

    [<Required(ErrorMessage = "Country is required")>]
    [<StringLength(100, MinimumLength = 1, ErrorMessage = "Country must be between 1 and 100 characters")>]
    [<RegularExpression(@"^[^<>{}\\]+$", ErrorMessage = "Country contains invalid characters")>]
    member val Country = "" with get, set

    [<Required(ErrorMessage = "Start date is required")>]
    [<RegularExpression(@"^\d{4}-\d{2}-\d{2}$", ErrorMessage = "Start date must be in YYYY-MM-DD format")>]
    member val StartDate = "" with get, set

    [<RegularExpression(@"^\d{4}-\d{2}-\d{2}$", ErrorMessage = "End date must be in YYYY-MM-DD format")>]
    member val EndDate = "" with get, set

// Legacy model - kept for backward compatibility
type NewEntryViewModel() =
    [<Required(ErrorMessage = "Name is required")>]
    [<StringLength(200, MinimumLength = 1, ErrorMessage = "Name must be between 1 and 200 characters")>]
    member val Name = "" with get, set

    [<Required(ErrorMessage = "Location is required")>]
    [<StringLength(100, MinimumLength = 1, ErrorMessage = "Location must be between 1 and 100 characters")>]
    member val Location = "" with get, set

    [<Required(ErrorMessage = "Country is required")>]
    [<StringLength(100, MinimumLength = 1, ErrorMessage = "Country must be between 1 and 100 characters")>]
    member val Country = "" with get, set

    [<Required(ErrorMessage = "Trip dates are required")>]
    member val TripDates = "" with get, set

    member val Description = "" with get, set
