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
        match DateTime.TryParseExact(isoDate, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None) with
        | true, date -> date.ToString("dd MMM, yyyy")
        | false, _ -> isoDate

    let generateDisplayText (startDate: string) (endDate: string option) =
        let formattedStart = formatDateForDisplay startDate
        match endDate with
        | Some endDateStr when not (String.IsNullOrWhiteSpace(endDateStr)) ->
            let formattedEnd = formatDateForDisplay endDateStr
            if formattedStart = formattedEnd then
                formattedStart
            else
                sprintf "%s-%s" (formattedStart.Substring(0, 2)) formattedEnd
        | _ -> formattedStart

    let buildTripDates (startDate: string) (endDateRaw: string) =
        let endDate = if isNull endDateRaw then None else Some endDateRaw
        {
            StartDate = startDate
            EndDate = endDate
            IsSingleDay = isNull endDateRaw
            DisplayText = generateDisplayText startDate endDate
        }

    let toPlaceDetailPage (place: Place) =
        let tripDates = buildTripDates place.StartDate place.EndDate
        let photos =
            place.Photos
                .OrderBy(fun ph -> ph.PhotoNum)
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

    let getFavoritePhoto (photos: ResizeArray<Photo>) =
        if photos.Count = 0 then
            None, None
        else
            let favorite = photos |> Seq.tryFind (fun ph -> ph.IsFavorite)
            match favorite with
            | Some photo -> Some photo.PhotoNum, Some photo.FileName
            | None ->
                let first = photos |> Seq.minBy (fun ph -> ph.PhotoNum)
                Some first.PhotoNum, Some first.FileName

    member _.GetAllPlacesAsync() =
        task {
            let! places =
                context.Places
                    .AsNoTracking()
                    .Include(fun p -> p.Photos :> obj)
                    .OrderByDescending(fun p -> p.CreatedAt)
                    .ToListAsync()

            logger.LogDebug("Loaded {Count} places from database", places.Count)

            return places
                |> Seq.map (fun p ->
                    let tripDates = buildTripDates p.StartDate p.EndDate
                    let favoritePhotoNum, favoritePhotoFileName = getFavoritePhoto p.Photos

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

    member _.GetPlaceByIdAsync(id: int) =
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

    member _.GetPlaceBySlugAsync(slug: string) =
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

    member _.CreatePlaceAsync(name: string, location: string, country: string, startDate: string, endDate: string option) =
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

    member _.UpdatePlaceAsync(id: int, name: string, location: string, country: string, startDate: string, endDate: string option) =
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

    member _.DeletePlaceAsync(id: int) =
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

    member _.IncrementFavoritesAsync(id: int) =
        task {
            let! place = context.Places.FindAsync(id)

            if not (isNull place) then
                place.Favorites <- place.Favorites + 1
                place.UpdatedAt <- DateTime.UtcNow
                let! _ = context.SaveChangesAsync()
                logger.LogDebug("Incremented favorites for place {PlaceId} to {Count}", id, place.Favorites)
        }

    member _.GetTotalFavoritesAsync() =
        task {
            let! total = context.Places.SumAsync(fun p -> p.Favorites)
            return total
        }

    member _.GetPlaceCountAsync() =
        task {
            let! count = context.Places.CountAsync()
            return count
        }
