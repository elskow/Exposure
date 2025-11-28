namespace Gallery.Services

open System
open System.Globalization
open System.Linq
open System.Threading
open Microsoft.EntityFrameworkCore
open Gallery.Data
open Gallery.Models

type PlaceService(context: GalleryDbContext, slugGenerator: SlugGeneratorService) =

    // Static lock to prevent race conditions when creating places with duplicate slugs
    static let createPlaceLock = new SemaphoreSlim(1, 1)

    // Helper to format ISO date (YYYY-MM-DD) to display format (DD MMM, YYYY)
    let formatDateForDisplay (isoDate: string) =
        try
            let date = DateTime.ParseExact(isoDate, "yyyy-MM-dd", CultureInfo.InvariantCulture)
            date.ToString("dd MMM, yyyy")
        with
        | _ -> isoDate // Return as-is if parsing fails

    // Helper to generate display text for trip dates
    let generateDisplayText (startDate: string) (endDate: string option) =
        let formattedStart = formatDateForDisplay startDate
        match endDate with
        | None -> formattedStart
        | Some endDateStr when not (String.IsNullOrWhiteSpace(endDateStr)) ->
            let formattedEnd = formatDateForDisplay endDateStr
            // If same date, show single date
            if formattedStart = formattedEnd then formattedStart
            else
                // Extract day parts for range display
                let startDay = formattedStart.Substring(0, 2)
                let endParts = formattedEnd.Split(' ')
                sprintf "%s-%s" startDay formattedEnd
        | _ -> formattedStart

    // Get all places with photo counts
    member this.GetAllPlacesAsync() =
        task {
            let! places =
                context.Places
                    .Include(fun p -> p.Photos :> obj)
                    .OrderByDescending(fun p -> p.CreatedAt :> obj)
                    .ToListAsync()

            return places
                |> Seq.map (fun p ->
                    let endDate =
                        if isNull p.EndDate then None
                        else Some(p.EndDate)

                    let isSingleDay = isNull p.EndDate

                    let displayText = generateDisplayText p.StartDate endDate

                    // Get favorite photo or first photo
                    let favoritePhotoNum, favoritePhotoFileName =
                        let favoritePhoto = p.Photos |> Seq.tryFind (fun ph -> ph.IsFavorite)
                        match favoritePhoto with
                        | Some photo -> Some(photo.PhotoNum), Some(photo.FileName)
                        | None ->
                            let firstPhoto = p.Photos |> Seq.sortBy (fun ph -> ph.PhotoNum) |> Seq.tryHead
                            match firstPhoto with
                            | Some photo -> Some(photo.PhotoNum), Some(photo.FileName)
                            | None -> None, None

                    {
                        Id = p.Id
                        Slug = p.Slug
                        Name = p.Name
                        Location = p.Location
                        Country = p.Country
                        Photos = p.Photos.Count
                        TripDates = {
                            StartDate = p.StartDate
                            EndDate = endDate
                            IsSingleDay = isSingleDay
                            DisplayText = displayText
                        }
                        FavoritePhotoNum = favoritePhotoNum
                        FavoritePhotoFileName = favoritePhotoFileName
                    }
                )
                |> List.ofSeq
        }

    // Get place by ID with all photos
    member this.GetPlaceByIdAsync(id: int) =
        task {
            let! place =
                context.Places
                    .Include(fun p -> p.Photos :> obj)
                    .FirstOrDefaultAsync(fun p -> p.Id = id)

            if isNull place then
                return None
            else
                let endDate =
                    if isNull place.EndDate then None
                    else Some(place.EndDate)

                let isSingleDay = isNull place.EndDate

                let displayText = generateDisplayText place.StartDate endDate

                let photos =
                    place.Photos
                        .OrderBy(fun ph -> ph.PhotoNum :> obj)
                        .Select(fun ph -> {
                            Num = ph.PhotoNum
                            Slug = ph.Slug
                            FileName = ph.FileName
                            IsFavorite = ph.IsFavorite
                        })
                        |> List.ofSeq

                let placeDetail = {
                    PlaceId = place.Id
                    PlaceSlug = place.Slug
                    Name = place.Name
                    Location = place.Location
                    Country = place.Country
                    TotalPhotos = place.Photos.Count
                    Favorites = place.Favorites
                    TripDates = {
                        StartDate = place.StartDate
                        EndDate = endDate
                        IsSingleDay = isSingleDay
                        DisplayText = displayText
                    }
                    Photos = photos
                }

                return Some(placeDetail)
        }

    // Get place by slug with all photos
    member this.GetPlaceBySlugAsync(slug: string) =
        task {
            let! place =
                context.Places
                    .Include(fun p -> p.Photos :> obj)
                    .FirstOrDefaultAsync(fun p -> p.Slug = slug)

            if isNull place then
                return None
            else
                let endDate =
                    if isNull place.EndDate then None
                    else Some(place.EndDate)

                let isSingleDay = isNull place.EndDate

                let displayText = generateDisplayText place.StartDate endDate

                let photos =
                    place.Photos
                        .OrderBy(fun ph -> ph.PhotoNum :> obj)
                        .Select(fun ph -> {
                            Num = ph.PhotoNum
                            Slug = ph.Slug
                            FileName = ph.FileName
                            IsFavorite = ph.IsFavorite
                        })
                        |> List.ofSeq

                let placeDetail = {
                    PlaceId = place.Id
                    PlaceSlug = place.Slug
                    Name = place.Name
                    Location = place.Location
                    Country = place.Country
                    TotalPhotos = place.Photos.Count
                    Favorites = place.Favorites
                    TripDates = {
                        StartDate = place.StartDate
                        EndDate = endDate
                        IsSingleDay = isSingleDay
                        DisplayText = displayText
                    }
                    Photos = photos
                }

                return Some(placeDetail)
        }

    // Create new place
    member this.CreatePlaceAsync(name: string, location: string, country: string, startDate: string, endDate: string option) =
        task {
            // Acquire lock to prevent duplicate slug race condition
            let! _ = createPlaceLock.WaitAsync()

            try
                let place = Place()

                // Generate unique slug
                let slugExists (slug: string) =
                    context.Places.Any(fun p -> p.Slug = slug)
                place.Slug <- slugGenerator.GenerateUniqueSlug(slugExists)

                place.Name <- name
                place.Location <- location
                place.Country <- country
                place.StartDate <- startDate
                place.EndDate <-
                    match endDate with
                    | Some date when not (String.IsNullOrWhiteSpace(date)) -> date
                    | _ -> null
                place.Favorites <- 0
                place.CreatedAt <- DateTime.UtcNow
                place.UpdatedAt <- DateTime.UtcNow

                context.Places.Add(place) |> ignore
                let! _ = context.SaveChangesAsync()

                return place.Id
            finally
                createPlaceLock.Release() |> ignore
        }

    // Update existing place
    member this.UpdatePlaceAsync(id: int, name: string, location: string, country: string, startDate: string, endDate: string option) =
        task {
            let! place = context.Places.FindAsync(id)

            if isNull place then
                return false
            else
                place.Name <- name
                place.Location <- location
                place.Country <- country
                place.StartDate <- startDate
                place.EndDate <-
                    match endDate with
                    | Some date when not (String.IsNullOrWhiteSpace(date)) -> date
                    | _ -> null
                place.UpdatedAt <- DateTime.UtcNow

                let! _ = context.SaveChangesAsync()
                return true
        }

    // Delete place (photos will be cascade deleted)
    member this.DeletePlaceAsync(id: int) =
        task {
            let! place = context.Places.FindAsync(id)

            if isNull place then
                return false
            else
                context.Places.Remove(place) |> ignore
                let! _ = context.SaveChangesAsync()
                return true
        }

    // Increment favorites count
    member this.IncrementFavoritesAsync(id: int) =
        task {
            let! place = context.Places.FindAsync(id)

            if not (isNull place) then
                place.Favorites <- place.Favorites + 1
                place.UpdatedAt <- DateTime.UtcNow
                let! _ = context.SaveChangesAsync()
                return ()
        }
