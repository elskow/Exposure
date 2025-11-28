namespace Gallery.Services

open System
open System.IO
open Microsoft.AspNetCore.Hosting
open Microsoft.Extensions.Logging

type PathValidationService(webHostEnvironment: IWebHostEnvironment, logger: ILogger<PathValidationService>) =

    // Get the absolute path of wwwroot
    let wwwRootPath = Path.GetFullPath(webHostEnvironment.WebRootPath)

    // Validate that an integer ID is within safe bounds
    member _.ValidateId(id: int, paramName: string) : Result<int, string> =
        if id < 1 then
            logger.LogWarning("Invalid {ParamName}: value {Value} is less than 1", paramName, id)
            Error (sprintf "%s must be greater than 0" paramName)
        elif id > 999999 then
            logger.LogWarning("Invalid {ParamName}: value {Value} exceeds maximum", paramName, id)
            Error (sprintf "%s exceeds maximum allowed value" paramName)
        else
            Ok id

    // Sanitize path component (remove any path traversal attempts)
    member _.SanitizePathComponent(pathComponent: string) : Result<string, string> =
        if String.IsNullOrWhiteSpace(pathComponent) then
            logger.LogWarning("Path validation failed: empty path component")
            Error "Invalid path"
        elif pathComponent.Contains("..") then
            logger.LogWarning("Path traversal attempt detected: path component contains '..' sequence: {PathComponent}", pathComponent)
            Error "Invalid path"
        elif pathComponent.Contains("/") || pathComponent.Contains("\\") then
            logger.LogWarning("Path traversal attempt detected: path component contains separator: {PathComponent}", pathComponent)
            Error "Invalid path"
        elif pathComponent.Contains(":") then
            logger.LogWarning("Path validation failed: path component contains colon: {PathComponent}", pathComponent)
            Error "Invalid path"
        elif pathComponent.StartsWith(".") then
            logger.LogWarning("Path validation failed: path component starts with dot: {PathComponent}", pathComponent)
            Error "Invalid path"
        else
            Ok pathComponent

    // Validate that a constructed path is within wwwroot
    member _.ValidatePathWithinWwwRoot(fullPath: string) : Result<string, string> =
        try
            // Get absolute path and normalize it
            let normalizedPath = Path.GetFullPath(fullPath)

            // Check if the path starts with wwwroot path
            if not (normalizedPath.StartsWith(wwwRootPath, StringComparison.OrdinalIgnoreCase)) then
                logger.LogWarning("Path traversal attempt blocked: attempted path {AttemptedPath} is outside wwwroot {WwwRoot}", normalizedPath, wwwRootPath)
                Error "Access denied"
            else
                Ok normalizedPath
        with
        | ex ->
            logger.LogError(ex, "Path validation error for path: {Path}", fullPath)
            Error "Invalid path"

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
                        logger.LogWarning("File not found: {FileName} for placeId {PlaceId}", validFileName, validPlaceId)
                        Error "File not found"

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
                    logger.LogInformation("Created directory for placeId {PlaceId}", placeId)
                Ok validPath
            with
            | ex ->
                logger.LogError(ex, "Failed to create directory for placeId {PlaceId}", placeId)
                Error "Failed to create directory"

    // Delete directory safely (with all contents)
    member this.DeleteDirectorySafely(placeId: int) : Result<unit, string> =
        match this.GetValidatedPhotoDirectory(placeId) with
        | Error msg -> Error msg
        | Ok validPath ->
            try
                if Directory.Exists(validPath) then
                    Directory.Delete(validPath, true)
                    logger.LogInformation("Deleted directory for placeId {PlaceId}", placeId)
                Ok ()
            with
            | ex ->
                logger.LogError(ex, "Failed to delete directory for placeId {PlaceId}", placeId)
                Error "Failed to delete directory"

    // Get info for debugging/logging (internal use only)
    member _.GetSecurityInfo() =
        sprintf "Protected Root: %s" wwwRootPath
