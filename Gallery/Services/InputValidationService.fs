namespace Gallery.Services

open System
open System.Text.RegularExpressions

type InputValidationService() =

    static let sqlInjectionRegexes =
        [|
            Regex(@"(\bOR
\b|\bAND\b).*(=|<|>)", RegexOptions.IgnoreCase ||| RegexOptions.Compiled)
            Regex(@"('|\"")\s*(OR|AND)\s*('|\"").*=.*('|\"").*", RegexOptions.IgnoreCase ||| RegexOptions.Compiled)
            Regex(@"(UNION|SELECT|INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|EXEC|EXECUTE)\s+", RegexOptions.IgnoreCase ||| RegexOptions.Compiled)
            Regex(@"(--|#|\/\*|\*\/)", RegexOptions.IgnoreCase ||| RegexOptions.Compiled)
            Regex(@"(xp_|sp_|0x[0-9a-fA-F]+)", RegexOptions.IgnoreCase ||| RegexOptions.Compiled)
        |]

    static let xssRegexes =
        [|
            Regex(@"<script[^>]*>.*?</script>", RegexOptions.IgnoreCase ||| RegexOptions.Compiled ||| RegexOptions.Singleline)
            Regex(@"javascript:", RegexOptions.IgnoreCase ||| RegexOptions.Compiled)
            Regex(@"on\w+\s*=", RegexOptions.IgnoreCase ||| RegexOptions.Compiled)
            Regex(@"<iframe[^>]*>", RegexOptions.IgnoreCase ||| RegexOptions.Compiled)
            Regex(@"<object[^>]*>", RegexOptions.IgnoreCase ||| RegexOptions.Compiled)
            Regex(@"<embed[^>]*>", RegexOptions.IgnoreCase ||| RegexOptions.Compiled)
        |]

    static let pathTraversalRegexes =
        [|
            Regex(@"\.\.", RegexOptions.IgnoreCase ||| RegexOptions.Compiled)
            Regex(@"(\\|/)\.\.(\\|/)", RegexOptions.IgnoreCase ||| RegexOptions.Compiled)
            Regex(@"%2e%2e", RegexOptions.IgnoreCase ||| RegexOptions.Compiled)
            Regex(@"\.{2,}", RegexOptions.IgnoreCase ||| RegexOptions.Compiled)
        |]

    static let isoDateRegex = Regex(@"^\d{4}-\d{2}-\d{2}$", RegexOptions.Compiled)
    static let usernameRegex = Regex(@"^[a-zA-Z0-9_-]+$", RegexOptions.Compiled)
    static let totpCodeRegex = Regex(@"^\d{6}$", RegexOptions.Compiled)

    member _.ContainsSqlInjection(input: string) : bool =
        if String.IsNullOrWhiteSpace(input) then
            false
        else
            sqlInjectionRegexes |> Array.exists (fun regex -> regex.IsMatch(input))

    member _.ContainsXss(input: string) : bool =
        if String.IsNullOrWhiteSpace(input) then
            false
        else
            xssRegexes |> Array.exists (fun regex -> regex.IsMatch(input))

    member _.ContainsPathTraversal(input: string) : bool =
        if String.IsNullOrWhiteSpace(input) then
            false
        else
            pathTraversalRegexes |> Array.exists (fun regex -> regex.IsMatch(input))

    member _.SanitizeString(input: string) : string =
        if String.IsNullOrWhiteSpace(input) then
            ""
        else
            input
                .Trim()
                .Replace("<", "&lt;")
                .Replace(">", "&gt;")
                .Replace("\"", "&quot;")
                .Replace("'", "&#x27;")
                .Replace("/", "&#x2F;")

    member _.ValidateLength(input: string, minLength: int, maxLength: int, fieldName: string) : Result<string, string> =
        if String.IsNullOrWhiteSpace(input) then
            Error (sprintf "%s cannot be empty" fieldName)
        elif input.Trim().Length < minLength then
            Error (sprintf "%s must be at least %d characters" fieldName minLength)
        elif input.Length > maxLength then
            Error (sprintf "%s cannot exceed %d characters" fieldName maxLength)
        else
            Ok (input.Trim())

    member this.ValidatePlaceName(name: string) : Result<string, string> =
        match this.ValidateLength(name, 1, 200, "Place name") with
        | Error msg -> Error msg
        | Ok trimmed ->
            if this.ContainsSqlInjection(trimmed) then
                Error "Place name contains invalid SQL characters"
            elif this.ContainsXss(trimmed) then
                Error "Place name contains invalid HTML/script characters"
            elif this.ContainsPathTraversal(trimmed) then
                Error "Place name contains path traversal characters"
            else
                Ok trimmed

    member this.ValidateLocation(location: string) : Result<string, string> =
        match this.ValidateLength(location, 1, 100, "Location") with
        | Error msg -> Error msg
        | Ok trimmed ->
            if this.ContainsSqlInjection(trimmed) then
                Error "Location contains invalid SQL characters"
            elif this.ContainsXss(trimmed) then
                Error "Location contains invalid HTML/script characters"
            elif this.ContainsPathTraversal(trimmed) then
                Error "Location contains path traversal characters"
            else
                Ok trimmed

    member this.ValidateCountry(country: string) : Result<string, string> =
        match this.ValidateLength(country, 1, 100, "Country") with
        | Error msg -> Error msg
        | Ok trimmed ->
            if this.ContainsSqlInjection(trimmed) then
                Error "Country contains invalid SQL characters"
            elif this.ContainsXss(trimmed) then
                Error "Country contains invalid HTML/script characters"
            elif this.ContainsPathTraversal(trimmed) then
                Error "Country contains path traversal characters"
            else
                Ok trimmed

    member _.ValidateIsoDate(dateString: string, fieldName: string) : Result<string, string> =
        if String.IsNullOrWhiteSpace(dateString) then
            Error (sprintf "%s cannot be empty" fieldName)
        else
            if not (isoDateRegex.IsMatch(dateString)) then
                Error (sprintf "%s must be in YYYY-MM-DD format" fieldName)
            else
                try
                    let date = DateTime.Parse(dateString)
                    if date.Year < 1900 || date.Year > 2100 then
                        Error (sprintf "%s year must be between 1900 and 2100" fieldName)
                    else
                        Ok dateString
                with
                | _ -> Error (sprintf "%s is not a valid date" fieldName)

    member this.ValidateOptionalIsoDate(dateString: string, fieldName: string) : Result<string option, string> =
        if String.IsNullOrWhiteSpace(dateString) then
            Ok None
        else
            match this.ValidateIsoDate(dateString, fieldName) with
            | Ok validDate -> Ok (Some validDate)
            | Error msg -> Error msg

    member _.ValidateDateRange(startDate: string, endDate: string option) : Result<unit, string> =
        match endDate with
        | None -> Ok ()
        | Some endDateStr when not (String.IsNullOrWhiteSpace(endDateStr)) ->
            try
                let start = DateTime.Parse(startDate)
                let endParsed = DateTime.Parse(endDateStr)
                if endParsed < start then
                    Error "End date cannot be before start date"
                else
                    Ok ()
            with
            | _ -> Error "Invalid date format in range validation"
        | _ -> Ok ()

    member this.ValidateUsername(username: string) : Result<string, string> =
        match this.ValidateLength(username, 3, 100, "Username") with
        | Error msg -> Error msg
        | Ok trimmed ->
            if not (usernameRegex.IsMatch(trimmed)) then
                Error "Username can only contain letters, numbers, underscores and hyphens"
            elif this.ContainsSqlInjection(trimmed) then
                Error "Username contains invalid characters"
            else
                Ok trimmed

    member _.ValidatePassword(password: string) : Result<string, string> =
        if String.IsNullOrWhiteSpace(password) then
            Error "Password cannot be empty"
        elif password.Length < 8 then
            Error "Password must be at least 8 characters"
        elif password.Length > 100 then
            Error "Password cannot exceed 100 characters"
        else
            Ok password

    member _.ValidateTotpCode(code: string) : Result<string, string> =
        if String.IsNullOrWhiteSpace(code) then
            Error "TOTP code cannot be empty"
        else
            if not (totpCodeRegex.IsMatch(code)) then
                Error "TOTP code must be exactly 6 digits"
            else
                Ok code

    member _.ValidateId(id: int, fieldName: string) : Result<int, string> =
        if id < 1 then
            Error (sprintf "%s must be greater than 0" fieldName)
        elif id > 999999 then
            Error (sprintf "%s exceeds maximum value" fieldName)
        else
            Ok id

    member this.ValidatePlaceForm(name: string, location: string, country: string, startDate: string, endDate: string) : Result<string * string * string * string * string option, string list> =
        let nameResult = this.ValidatePlaceName(name)
        let locationResult = this.ValidateLocation(location)
        let countryResult = this.ValidateCountry(country)
        let startDateResult = this.ValidateIsoDate(startDate, "Start date")
        let endDateResult = this.ValidateOptionalIsoDate(endDate, "End date")

        let errors =
            [ match nameResult with | Error msg -> yield msg | _ -> ()
              match locationResult with | Error msg -> yield msg | _ -> ()
              match countryResult with | Error msg -> yield msg | _ -> ()
              match startDateResult with | Error msg -> yield msg | _ -> ()
              match endDateResult with | Error msg -> yield msg | _ -> () ]

        if not errors.IsEmpty then
            Error errors
        else
            let validName = match nameResult with | Ok v -> v | _ -> ""
            let validLocation = match locationResult with | Ok v -> v | _ -> ""
            let validCountry = match countryResult with | Ok v -> v | _ -> ""
            let validStartDate = match startDateResult with | Ok v -> v | _ -> ""
            let validEndDate = match endDateResult with | Ok v -> v | _ -> None

            match this.ValidateDateRange(validStartDate, validEndDate) with
            | Error msg -> Error [msg]
            | Ok _ -> Ok (validName, validLocation, validCountry, validStartDate, validEndDate)
