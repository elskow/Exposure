namespace Gallery.Data

open Microsoft.EntityFrameworkCore
open Gallery.Models

type GalleryDbContext(options: DbContextOptions<GalleryDbContext>) =
    inherit DbContext(options)

    [<DefaultValue>]
    val mutable private places: DbSet<Place>

    [<DefaultValue>]
    val mutable private photos: DbSet<Photo>

    [<DefaultValue>]
    val mutable private adminUsers: DbSet<AdminUser>

    member this.Places
        with get() = this.places
        and set value = this.places <- value

    member this.Photos
        with get() = this.photos
        and set value = this.photos <- value

    member this.AdminUsers
        with get() = this.adminUsers
        and set value = this.adminUsers <- value

    override _.OnModelCreating(modelBuilder: ModelBuilder) =
        // Configure Place -> Photo relationship
        modelBuilder.Entity<Place>()
            .HasMany<Photo>("Photos")
            .WithOne("Place")
            .HasForeignKey("PlaceId")
            .OnDelete(DeleteBehavior.Cascade)
            |> ignore

        // Create unique index on Place Slug
        modelBuilder.Entity<Place>()
            .HasIndex("Slug")
            .IsUnique()
            |> ignore

        // Create unique index on PlaceId + PhotoNum
        modelBuilder.Entity<Photo>()
            .HasIndex("PlaceId", "PhotoNum")
            .IsUnique()
            |> ignore

        // Create unique index on PlaceId + Photo Slug (slug must be unique within each place)
        modelBuilder.Entity<Photo>()
            .HasIndex("PlaceId", "Slug")
            .IsUnique()
            |> ignore

        // Configure AdminUser
        modelBuilder.Entity<AdminUser>()
            .HasIndex("Username")
            .IsUnique()
            |> ignore
