namespace Gallery.Models

open System

type TripDates = {
    StartDate: string
    EndDate: string option
    IsSingleDay: bool
    DisplayText: string
}

type PlaceSummary = {
    Id: int
    Slug: string
    Name: string
    Location: string
    Country: string
    Photos: int
    TripDates: TripDates
    SortOrder: int
    FavoritePhotoNum: int option
    FavoritePhotoFileName: string option
}

type PhotoDetail = {
    Num: int
    Slug: string
    FileName: string
    IsFavorite: bool
}

type PlaceDetailPage = {
    PlaceId: int
    PlaceSlug: string
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
    PlaceSlug: string
    PhotoNum: int
    PhotoSlug: string
    FileName: string
    TotalPhotos: int
    PlaceName: string
    Location: string
    Country: string
    TripDates: TripDates
    UniqueId: string
    PrevPhoto: Nullable<int>
    NextPhoto: Nullable<int>
    PrevPhotoSlug: string option
    NextPhotoSlug: string option
    PrevPhotoFileName: string option
    NextPhotoFileName: string option
}
