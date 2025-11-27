namespace Gallery.Models

open System
open System.ComponentModel.DataAnnotations
open System.ComponentModel.DataAnnotations.Schema

[<AllowNullLiteral>]
[<Table("Places")>]
type Place() =
    [<Key>]
    member val Id = 0 with get, set

    [<Required>]
    [<MaxLength(200)>]
    member val Name = "" with get, set

    [<Required>]
    [<MaxLength(100)>]
    member val Location = "" with get, set

    [<Required>]
    [<MaxLength(100)>]
    member val Country = "" with get, set

    [<Required>]
    [<MaxLength(50)>]
    member val StartDate = "" with get, set

    [<MaxLength(50)>]
    member val EndDate : string = null with get, set

    member val Favorites = 0 with get, set

    member val CreatedAt = DateTime.UtcNow with get, set

    member val UpdatedAt = DateTime.UtcNow with get, set

    // Navigation property
    member val Photos : ResizeArray<Photo> = ResizeArray<Photo>() with get, set

and [<AllowNullLiteral>]
    [<Table("Photos")>]
    Photo() =
    [<Key>]
    member val Id = 0 with get, set

    [<Required>]
    member val PlaceId = 0 with get, set

    [<Required>]
    member val PhotoNum = 0 with get, set

    member val IsPortrait = false with get, set

    member val IsFavorite = false with get, set

    [<Required>]
    [<MaxLength(255)>]
    member val FileName = "" with get, set

    member val CreatedAt = DateTime.UtcNow with get, set

    // Navigation property
    [<ForeignKey("PlaceId")>]
    member val Place : Place = null with get, set
