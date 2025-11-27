namespace Gallery.Models

open System

// Represents a single Place on the Home Page
type PlaceSummary = {
    Id: int
    Name: string
    Location: string
    Country: string
    Photos: int
    Date: string
}

// Represents a single photo on the Place Detail page
type PhotoDetail = {
    Num: int
    IsPortrait: bool
}

// Represents the data needed for the Place Detail Page
type PlaceDetailPage = {
    PlaceId: int
    Name: string
    Location: string
    Country: string
    TotalPhotos: int
    Favorites: int
    Date: string
    Photos: PhotoDetail list
}

type PhotoViewModel = {
    PlaceId: int
    PhotoNum: int
    TotalPhotos: int
    PlaceName: string
    Location: string
    Country: string
    UniqueId: string
    PrevPhoto: Nullable<int> 
    NextPhoto: Nullable<int>
}