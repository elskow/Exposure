namespace Gallery.Data

open System
open Gallery.Models
open Gallery.Services

module SeedData =

    let seedPlaces (placeService: PlaceService) =
        task {
            // Check if database is already seeded
            let! existingPlaces = placeService.GetAllPlacesAsync()

            if List.isEmpty existingPlaces then
                printfn "Seeding database with sample data..."

                // Seed Place 1: Santorini Sunsets
                let! place1Id = placeService.CreatePlaceAsync(
                    "Santorini Sunsets",
                    "Oia",
                    "Greece",
                    "2024-06-15",
                    Some("2024-06-18")
                )

                // Seed Place 2: Tokyo Nights
                let! place2Id = placeService.CreatePlaceAsync(
                    "Tokyo Nights",
                    "Shibuya",
                    "Japan",
                    "2024-09-02",
                    Some("2024-09-10")
                )

                // Seed Place 3: Swiss Alps
                let! place3Id = placeService.CreatePlaceAsync(
                    "Swiss Alps",
                    "Zermatt",
                    "Switzerland",
                    "2024-12-05",
                    None
                )

                // Seed Place 4: Parisian Cafés
                let! place4Id = placeService.CreatePlaceAsync(
                    "Parisian Cafés",
                    "Le Marais",
                    "France",
                    "2025-08-10",
                    Some("2025-08-13")
                )

                printfn "Database seeded successfully with %d places!" 4
                printfn "Place IDs: %d, %d, %d, %d" place1Id place2Id place3Id place4Id
            else
                printfn "Database already contains %d place(s). Skipping seed." existingPlaces.Length
        }
