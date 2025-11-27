namespace Gallery.Services

open System
open System.IO
open System.Text.Json
open Gallery.Models

type DummyDataService() =

    let mutable placesData: PlaceSummary list = []
    let mutable placeDetails: Map<int, PlaceDetailPage> = Map.empty

    member _.LoadData() =
        try
            let jsonPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Data", "dummy-data.json")
            if File.Exists(jsonPath) then
                let jsonContent = File.ReadAllText(jsonPath)
                let options = JsonSerializerOptions(PropertyNameCaseInsensitive = true)
                let data = JsonSerializer.Deserialize<JsonElement>(jsonContent, options)

                let places =
                    data.GetProperty("places").EnumerateArray()
                    |> Seq.map (fun placeElement ->
                        let id = placeElement.GetProperty("id").GetInt32()
                        let name = placeElement.GetProperty("name").GetString()
                        let location = placeElement.GetProperty("location").GetString()
                        let country = placeElement.GetProperty("country").GetString()
                        let totalPhotos = placeElement.GetProperty("totalPhotos").GetInt32()

                        let tripDatesElement = placeElement.GetProperty("tripDates")
                        let startDate = tripDatesElement.GetProperty("startDate").GetString()
                        let endDateElement = tripDatesElement.GetProperty("endDate")
                        let endDate = if endDateElement.ValueKind = JsonValueKind.Null then None else Some(endDateElement.GetString())
                        let isSingleDay = tripDatesElement.GetProperty("isSingleDay").GetBoolean()
                        let displayText = tripDatesElement.GetProperty("displayText").GetString()

                        let tripDates = {
                            StartDate = startDate
                            EndDate = endDate
                            IsSingleDay = isSingleDay
                            DisplayText = displayText
                        }

                        {
                            Id = id
                            Name = name
                            Location = location
                            Country = country
                            Photos = totalPhotos
                            TripDates = tripDates
                        }
                    )
                    |> List.ofSeq

                let details =
                    data.GetProperty("places").EnumerateArray()
                    |> Seq.map (fun placeElement ->
                        let id = placeElement.GetProperty("id").GetInt32()
                        let name = placeElement.GetProperty("name").GetString()
                        let location = placeElement.GetProperty("location").GetString()
                        let country = placeElement.GetProperty("country").GetString()
                        let totalPhotos = placeElement.GetProperty("totalPhotos").GetInt32()
                        let favorites = placeElement.GetProperty("favorites").GetInt32()

                        let tripDatesElement = placeElement.GetProperty("tripDates")
                        let startDate = tripDatesElement.GetProperty("startDate").GetString()
                        let endDateElement = tripDatesElement.GetProperty("endDate")
                        let endDate = if endDateElement.ValueKind = JsonValueKind.Null then None else Some(endDateElement.GetString())
                        let isSingleDay = tripDatesElement.GetProperty("isSingleDay").GetBoolean()
                        let displayText = tripDatesElement.GetProperty("displayText").GetString()

                        let tripDates = {
                            StartDate = startDate
                            EndDate = endDate
                            IsSingleDay = isSingleDay
                            DisplayText = displayText
                        }

                        let photos =
                            placeElement.GetProperty("photos").EnumerateArray()
                            |> Seq.map (fun photoElement ->
                                {
                                    Num = photoElement.GetProperty("num").GetInt32()
                                    IsPortrait = photoElement.GetProperty("isPortrait").GetBoolean()
                                }
                            )
                            |> List.ofSeq

                        let detailPage = {
                            PlaceId = id
                            Name = name
                            Location = location
                            Country = country
                            TotalPhotos = totalPhotos
                            Favorites = favorites
                            TripDates = tripDates
                            Photos = photos
                        }

                        (id, detailPage)
                    )
                    |> Map.ofSeq

                placesData <- places
                placeDetails <- details
                true
            else
                false
        with
        | ex ->
            printfn "Error loading dummy data: %s" ex.Message
            false

    member this.GetAllPlaces() =
        if List.isEmpty placesData then
            this.LoadData() |> ignore
        placesData

    member this.GetPlaceById(id: int) =
        if Map.isEmpty placeDetails then
            this.LoadData() |> ignore
        Map.tryFind id placeDetails

    member this.GetPhotoViewModel(placeId: int, photoNum: int) =
        match this.GetPlaceById(placeId) with
        | Some placeDetail ->
            let totalPhotos = placeDetail.TotalPhotos
            let prevOpt = if photoNum > 1 then Some(photoNum - 1) else None
            let nextOpt = if photoNum < totalPhotos then Some(photoNum + 1) else None
            let uniqueId = sprintf "PH/%X" (photoNum * 12345)

            Some {
                PlaceId = placeId
                PhotoNum = photoNum
                TotalPhotos = totalPhotos
                PlaceName = placeDetail.Name
                Location = placeDetail.Location
                Country = placeDetail.Country
                TripDates = placeDetail.TripDates
                UniqueId = uniqueId
                PrevPhoto = Option.toNullable prevOpt
                NextPhoto = Option.toNullable nextOpt
            }
        | None -> None
