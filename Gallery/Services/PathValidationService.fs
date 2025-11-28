namespace Gallery.Services

open System
open System.IO
open Microsoft.AspNetCore.Hosting

type PathValidationService(webHostEnvironment: IWebHostEnvironment) =

    // Get the absolute path of wwwroot
    let wwwRootPath = Path.GetFullPath(webHostEnvironment.WebRootPath)

    // Validate that an integer ID is within safe bounds
    member _.ValidateId(id: int, paramName: string) : Result<int, string> =
        if id < 1 then
            Error (sprintf "%s must be greater than 0" paramName)
        elif id > 999999 then
            Error (sprintf "%s exceeds maximum allowed value (999999)" paramName)
        else
            Ok id

    // Sanitize path component (remove any path traversal attempts)
    member _.SanitizePathComponent(pathComponent: string) : Result<string, string> =
        if String.IsNullOrWhiteSpace(pathComponent) then
            Error "Path component cannot be empty"
        elif pathComponent.Contains("..") then
            Error "Path component contains invalid sequence (..)"
        elif pathComponent.Contains("/") || pathComponent.Contains("\\") then
            Error "Path component contains invalid path separator"
        elif pathComponent.Contains(":") then
            Error "Path component contains invalid character (:)"
        elif pathComponent.StartsWith(".") then
            Error "Path component cannot start with dot"
        else
            Ok pathComponent

    // Validate that a constructed path is within wwwroot
    member _.ValidatePathWithinWwwRoot(fullPath: string) : Result<string, string> =
        try
            // Get absolute path and normalize it
            let normalizedPath = Path.GetFullPath(fullPath)

            // Check if the path starts with wwwroot path
            if not (normalizedPath.StartsWith(wwwRootPath, StringComparison.OrdinalIgnoreCase)) then
                Error (sprintf "Path is outside allowed directory. Attempted path: %s" normalizedPath)
            else
                Ok normalizedPath
        with
        | ex -> Error (sprintf "Invalid path: %s" ex.Message)

    // Build and validate photo directory path
    member this.GetValidatedPhotoDirectory(placeId: int) : Result<string, string> =
        match this.ValidateId(placeId, "placeId") with
        | Error msg -> Error msg
        | Ok validId ->
            // Build path using only validated integer
            let relativePath = Path.Combine("images", "places", validId.ToString())
            let fullPath = Path.Combine(wwwRootPath, relativePath)

            // Validate the constructed path is within wwwroot
            this.ValidatePathWithinWwwRoot(fullPath)

    // Build and validate full photo file path using fileName
    member this.GetValidatedPhotoPath(placeId: int, fileName: string) : Result<string, string> =
        match this.ValidateId(placeId, "placeId") with
        | Error msg -> Error msg
        | Ok validPlaceId ->
            match this.SanitizePathComponent(fileName) with
            | Error msg -> Error msg
            | Ok validFileName ->
                // Build path using only validated components
                let relativePath = Path.Combine("images", "places", validPlaceId.ToString(), validFileName)
                let fullPath = Path.Combine(wwwRootPath, relativePath)

                // Final validation that path is within wwwroot
                this.ValidatePathWithinWwwRoot(fullPath)

    // Validate and get photo path for existing file
    member this.GetValidatedExistingPhotoPath(placeId: int, fileName: string) : Result<string, string> =
        match this.ValidateId(placeId, "placeId") with
        | Error msg -> Error msg
        | Ok validPlaceId ->
            match this.SanitizePathComponent(fileName) with
            | Error msg -> Error msg
            | Ok validFileName ->
                // Build path
                let relativePath = Path.Combine("images", "places", validPlaceId.ToString(), validFileName)
                let fullPath = Path.Combine(wwwRootPath, relativePath)

                // Validate path is within wwwroot
                match this.ValidatePathWithinWwwRoot(fullPath) with
                | Error msg -> Error msg
                | Ok validPath ->
                    // Check file exists
                    if File.Exists(validPath) then
                        Ok validPath
                    else
                        Error (sprintf "File does not exist: %s" fileName)

    // Check if path exists and is safe
    member this.PathExistsAndIsSafe(fullPath: string) : Result<bool, string> =
        match this.ValidatePathWithinWwwRoot(fullPath) with
        | Error msg -> Error msg
        | Ok validPath -> Ok (File.Exists(validPath) || Directory.Exists(validPath))

    // Create directory safely
    member this.CreateDirectorySafely(placeId: int) : Result<string, string> =
        match this.GetValidatedPhotoDirectory(placeId) with
        | Error msg -> Error msg
        | Ok validPath ->
            try
                if not (Directory.Exists(validPath)) then
                    Directory.CreateDirectory(validPath) |> ignore
                Ok validPath
            with
            | ex -> Error (sprintf "Failed to create directory: %s" ex.Message)

    // Delete directory safely (with all contents)
    member this.DeleteDirectorySafely(placeId: int) : Result<unit, string> =
        match this.GetValidatedPhotoDirectory(placeId) with
        | Error msg -> Error msg
        | Ok validPath ->
            try
                if Directory.Exists(validPath) then
                    Directory.Delete(validPath, true)
                Ok ()
            with
            | ex -> Error (sprintf "Failed to delete directory: %s" ex.Message)

    // Get info for debugging/logging
    member _.GetSecurityInfo() =
        sprintf "Protected Root: %s" wwwRootPath
