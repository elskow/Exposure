namespace Gallery.Data

open Microsoft.EntityFrameworkCore
open Gallery.Models

type GalleryDbContext(options: DbContextOptions<GalleryDbContext>) =
    inherit DbContext(options)

    [<DefaultValue>]
    val mutable private places: DbSet<Place>

    [<DefaultValue>]
    val mutable private photos: DbSet<Photo>

    member this.Places
        with get() = this.places
        and set value = this.places <- value

    member this.Photos
        with get() = this.photos
        and set value = this.photos <- value

    override _.OnModelCreating(modelBuilder: ModelBuilder) =
        // Configure Place -> Photo relationship
        modelBuilder.Entity<Place>()
            .HasMany<Photo>("Photos")
            .WithOne("Place")
            .HasForeignKey("PlaceId")
            .OnDelete(DeleteBehavior.Cascade)
            |> ignore

        // Create unique index on PlaceId + PhotoNum
        modelBuilder.Entity<Photo>()
            .HasIndex("PlaceId", "PhotoNum")
            .IsUnique()
            |> ignore
