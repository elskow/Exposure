namespace Gallery.Services

open System
open System.IO
open Microsoft.AspNetCore.Hosting
open Microsoft.Extensions.Logging

type PathValidationService(webHostEnvironment: IWebHostEnvironment, logger: ILogger<PathValidationService>) =

    let wwwRootPath = Path.GetFullPath(webHostEnvironment.WebRootPath)

    member _.ValidateId(id: int, paramName: string) : Result<int, string> =
        if id < 1 then
            logger.LogWarning("Invalid {ParamName}: value {Value} is less than 1", paramName, id)
            Error (sprintf "%s must be greater than 0" paramName)
        elif id > 999999 then
            logger.LogWarning("Invalid {ParamName}: value {Value} exceeds maximum", paramName, id)
            Error (sprintf "%s exceeds maximum allowed value" paramName)
        else
            Ok id

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

    member _.ValidatePathWithinWwwRoot(fullPath: string) : Result<string, string> =
        try
            let normalizedPath = Path.GetFullPath(fullPath)

            if not (normalizedPath.StartsWith(wwwRootPath, StringComparison.OrdinalIgnoreCase)) then
                logger.LogWarning("Path traversal attempt blocked: attempted path {AttemptedPath} is outside wwwroot {WwwRoot}", normalizedPath, wwwRootPath)
                Error "Access denied"
            else
                Ok normalizedPath
        with
        | ex ->
            logger.LogError(ex, "Path validation error for path: {Path}", fullPath)
            Error "Invalid path"

    member this.GetValidatedPhotoDirectory(placeId: int) : Result<string, string> =
        match this.ValidateId(placeId, "placeId") with
        | Error msg -> Error msg
        | Ok validId ->
            let relativePath = Path.Combine("images", "places", validId.ToString())
            let fullPath = Path.Combine(wwwRootPath, relativePath)
            this.ValidatePathWithinWwwRoot(fullPath)

    member this.GetValidatedPhotoPath(placeId: int, fileName: string) : Result<string, string> =
        match this.ValidateId(placeId, "placeId") with
        | Error msg -> Error msg
        | Ok validPlaceId ->
            match this.SanitizePathComponent(fileName) with
            | Error msg -> Error msg
            | Ok validFileName ->
                let relativePath = Path.Combine("images", "places", validPlaceId.ToString(), validFileName)
                let fullPath = Path.Combine(wwwRootPath, relativePath)
                this.ValidatePathWithinWwwRoot(fullPath)

    member this.GetValidatedExistingPhotoPath(placeId: int, fileName: string) : Result<string, string> =
        match this.ValidateId(placeId, "placeId") with
        | Error msg -> Error msg
        | Ok validPlaceId ->
            match this.SanitizePathComponent(fileName) with
            | Error msg -> Error msg
            | Ok validFileName ->
                let relativePath = Path.Combine("images", "places", validPlaceId.ToString(), validFileName)
                let fullPath = Path.Combine(wwwRootPath, relativePath)

                match this.ValidatePathWithinWwwRoot(fullPath) with
                | Error msg -> Error msg
                | Ok validPath ->
                    if File.Exists(validPath) then
                        Ok validPath
                    else
                        logger.LogWarning("File not found: {FileName} for placeId {PlaceId}", validFileName, validPlaceId)
                        Error "File not found"

    member this.PathExistsAndIsSafe(fullPath: string) : Result<bool, string> =
        match this.ValidatePathWithinWwwRoot(fullPath) with
        | Error msg -> Error msg
        | Ok validPath -> Ok (File.Exists(validPath) || Directory.Exists(validPath))

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
