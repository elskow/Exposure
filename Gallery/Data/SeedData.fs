namespace Gallery.Data

open Microsoft.Extensions.Logging
open Gallery.Services

module SeedData =

    let seedPlaces (placeService: PlaceService) (logger: ILogger) =
        task {
            let! existingPlaces = placeService.GetAllPlacesAsync()

            if List.isEmpty existingPlaces then
                logger.LogInformation("Seeding database with sample data...")

                let! place1Slug = placeService.CreatePlaceAsync(
                    "Santorini Sunsets",
                    "Oia",
                    "Greece",
                    "2024-06-15",
                    Some("2024-06-18")
                )

                let! place2Slug = placeService.CreatePlaceAsync(
                    "Tokyo Nights",
                    "Shibuya",
                    "Japan",
                    "2024-09-02",
                    Some("2024-09-10")
                )

                let! place3Slug = placeService.CreatePlaceAsync(
                    "Swiss Alps",
                    "Zermatt",
                    "Switzerland",
                    "2024-12-05",
                    None
                )

                let! place4Slug = placeService.CreatePlaceAsync(
                    "Parisian Cafés",
                    "Le Marais",
                    "France",
                    "2025-08-10",
                    Some("2025-08-13")
                )

                logger.LogInformation("Database seeded successfully with {Count} places!", 4)
                logger.LogDebug("Place slugs: {Place1}, {Place2}, {Place3}, {Place4}", place1Slug, place2Slug, place3Slug, place4Slug)
            else
                logger.LogInformation("Database already contains {Count} place(s). Skipping seed.", existingPlaces.Length)
        }
