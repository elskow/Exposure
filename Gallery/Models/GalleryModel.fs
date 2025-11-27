namespace Gallery.Models

open System

// Represents trip date information
type TripDates = {
    StartDate: string
    EndDate: string option
    IsSingleDay: bool
    DisplayText: string
}

// Represents a single Place on the Home Page
type PlaceSummary = {
    Id: int
    Name: string
    Location: string
    Country: string
    Photos: int
    TripDates: TripDates
    FavoritePhotoNum: int option
}

// Represents a single photo on the Place Detail page
type PhotoDetail = {
    Num: int
    IsPortrait: bool
    IsFavorite: bool
}

// Represents the data needed for the Place Detail Page
type PlaceDetailPage = {
    PlaceId: int
    Name: string
    Location: string
    Country: string
    TotalPhotos: int
    Favorites: int
    TripDates: TripDates
    Photos: PhotoDetail list
}

type PhotoViewModel = {
    PlaceId: int
    PhotoNum: int
    TotalPhotos: int
    PlaceName: string
    Location: string
    Country: string
    TripDates: TripDates
    UniqueId: string
    PrevPhoto: Nullable<int>
    NextPhoto: Nullable<int>
}
