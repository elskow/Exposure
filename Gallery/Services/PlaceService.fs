namespace Gallery.Services

open System
open System.Globalization
open System.Linq
open System.Threading
open Microsoft.EntityFrameworkCore
open Microsoft.Extensions.Logging
open Gallery.Data
open Gallery.Models

type PlaceService(context: GalleryDbContext, slugGenerator: SlugGeneratorService, logger: ILogger<PlaceService>) =

    static let createPlaceLock = new SemaphoreSlim(1, 1)

    let formatDateForDisplay (isoDate: string) =
        try
            let date = DateTime.ParseExact(isoDate, "yyyy-MM-dd", CultureInfo.InvariantCulture)
            date.ToString("dd MMM, yyyy")
        with
        | _ -> isoDate

    let generateDisplayText (startDate: string) (endDate: string option) =
        let formattedStart = formatDateForDisplay startDate
        match endDate with
        | None -> formattedStart
        | Some endDateStr when not (String.IsNullOrWhiteSpace(endDateStr)) ->
            let formattedEnd = formatDateForDisplay endDateStr
            if formattedStart = formattedEnd then formattedStart
            else
                let startDay = formattedStart.Substring(0, 2)
                sprintf "%s-%s" startDay formattedEnd
        | _ -> formattedStart

    let buildTripDates (startDate: string) (endDateRaw: string) =
        let endDate = if isNull endDateRaw then None else Some(endDateRaw)
        let isSingleDay = isNull endDateRaw
        let displayText = generateDisplayText startDate endDate
        {
            StartDate = startDate
            EndDate = endDate
            IsSingleDay = isSingleDay
            DisplayText = displayText
        }

    let toPlaceDetailPage (place: Place) =
        let tripDates = buildTripDates place.StartDate place.EndDate

        let photos =
            place.Photos
                .OrderBy(fun ph -> ph.PhotoNum :> obj)
                .Select(fun ph -> {
                    Num = ph.PhotoNum
                    Slug = ph.Slug
                    FileName = ph.FileName
                    IsFavorite = ph.IsFavorite
                })
            |> Seq.toList

        {
            PlaceId = place.Id
            PlaceSlug = place.Slug
            Name = place.Name
            Location = place.Location
            Country = place.Country
            TotalPhotos = place.Photos.Count
            Favorites = place.Favorites
            TripDates = tripDates
            Photos = photos
        }

    member this.GetAllPlacesAsync() =
        task {
            let! places =
                context.Places
                    .AsNoTracking()
                    .Include(fun p -> p.Photos :> obj)
                    .OrderByDescending(fun p -> p.CreatedAt :> obj)
                    .ToListAsync()

            logger.LogDebug("Loaded {Count} places from database", places.Count)

            return places
                |> Seq.map (fun p ->
                    let tripDates = buildTripDates p.StartDate p.EndDate

                    let favoritePhotoNum, favoritePhotoFileName =
                        let photos = p.Photos |> Seq.sortBy (fun ph -> ph.PhotoNum) |> Seq.toArray
                        if photos.Length = 0 then
                            None, None
                        else
                            match photos |> Array.tryFind (fun ph -> ph.IsFavorite) with
                            | Some photo -> Some(photo.PhotoNum), Some(photo.FileName)
                            | None -> Some(photos.[0].PhotoNum), Some(photos.[0].FileName)

                    {
                        Id = p.Id
                        Slug = p.Slug
                        Name = p.Name
                        Location = p.Location
                        Country = p.Country
                        Photos = p.Photos.Count
                        TripDates = tripDates
                        FavoritePhotoNum = favoritePhotoNum
                        FavoritePhotoFileName = favoritePhotoFileName
                    }
                )
                |> Seq.toList
        }

    member this.GetPlaceByIdAsync(id: int) =
        task {
            let! place =
                context.Places
                    .AsNoTracking()
                    .Include(fun p -> p.Photos :> obj)
                    .FirstOrDefaultAsync(fun p -> p.Id = id)

            if isNull place then
                return None
            else
                return Some(toPlaceDetailPage place)
        }

    member this.GetPlaceBySlugAsync(slug: string) =
        task {
            let! place =
                context.Places
                    .AsNoTracking()
                    .Include(fun p -> p.Photos :> obj)
                    .FirstOrDefaultAsync(fun p -> p.Slug = slug)

            if isNull place then
                return None
            else
                return Some(toPlaceDetailPage place)
        }

    member this.CreatePlaceAsync(name: string, location: string, country: string, startDate: string, endDate: string option) =
        task {
            let! _ = createPlaceLock.WaitAsync()

            try
                let place = Place()

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

                logger.LogInformation("Created place {PlaceId}: {Name} ({Slug})", place.Id, place.Name, place.Slug)
                return place.Id
            finally
                createPlaceLock.Release() |> ignore
        }

    member this.UpdatePlaceAsync(id: int, name: string, location: string, country: string, startDate: string, endDate: string option) =
        task {
            let! place = context.Places.FindAsync(id)

            if isNull place then
                logger.LogWarning("Place not found for update: {PlaceId}", id)
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
                logger.LogInformation("Updated place {PlaceId}: {Name}", id, name)
                return true
        }

    member this.DeletePlaceAsync(id: int) =
        task {
            let! place = context.Places.FindAsync(id)

            if isNull place then
                logger.LogWarning("Place not found for deletion: {PlaceId}", id)
                return false
            else
                let placeName = place.Name
                context.Places.Remove(place) |> ignore
                let! _ = context.SaveChangesAsync()
                logger.LogInformation("Deleted place {PlaceId}: {Name}", id, placeName)
                return true
        }

    member this.IncrementFavoritesAsync(id: int) =
        task {
            let! place = context.Places.FindAsync(id)

            if not (isNull place) then
                place.Favorites <- place.Favorites + 1
                place.UpdatedAt <- DateTime.UtcNow
                let! _ = context.SaveChangesAsync()
                logger.LogDebug("Incremented favorites for place {PlaceId} to {Count}", id, place.Favorites)
                return ()
        }

    member this.GetTotalFavoritesAsync() =
        task {
            let! total = context.Places.SumAsync(fun p -> p.Favorites)
            return total
        }

    member this.GetPlaceCountAsync() =
        task {
            let! count = context.Places.CountAsync()
            return count
        }
