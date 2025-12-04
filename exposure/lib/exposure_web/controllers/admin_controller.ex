defmodule ExposureWeb.AdminController do
  use ExposureWeb, :controller

  alias Exposure.Observability, as: Log
  alias Exposure.Services.{Authentication, InputValidation, OIDC, Photo, RateLimiter}

  plug(:require_auth when action not in [:login, :do_login, :oidc_login, :oidc_callback])

  # Safe integer parsing that returns {:ok, integer} or {:error, message}
  defp safe_parse_integer(value, _field_name) when is_integer(value), do: {:ok, value}

  defp safe_parse_integer(value, field_name) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "Invalid #{field_name}"}
    end
  end

  defp safe_parse_integer(_, field_name), do: {:error, "Invalid #{field_name}"}

  # =============================================================================
  # Dashboard
  # =============================================================================

  def index(conn, _params) do
    places = Exposure.list_places_with_stats()
    total_photos = Enum.sum(Enum.map(places, fn p -> p.photo_count end))
    total_favorites = Exposure.total_favorites()

    place_summaries =
      Enum.map(places, fn place ->
        %{
          id: place.id,
          name: place.name,
          location: place.location,
          country: place.country,
          photos: place.photo_count,
          trip_dates: Exposure.trip_dates_display(place.start_date, place.end_date),
          sort_order: place.sort_order,
          favorite_photo_num: place.favorite_photo_num,
          favorite_photo_file_name: place.favorite_photo_file_name
        }
      end)

    render(conn, :index,
      total_places: length(places),
      total_photos: total_photos,
      total_favorites: total_favorites,
      places: place_summaries
    )
  end

  # =============================================================================
  # Authentication
  # =============================================================================

  def login(conn, _params) do
    if get_session(conn, :admin_user_id) do
      redirect(conn, to: ~p"/admin")
    else
      # If only OIDC is enabled and there's no error flash, redirect directly to OIDC login
      # We check for flash errors to avoid redirect loops when OIDC config is broken
      has_error = conn.assigns[:flash] && Phoenix.Flash.get(conn.assigns[:flash], :error)

      if OIDC.enabled?() and not OIDC.local_auth_enabled?() and is_nil(has_error) do
        redirect(conn, to: ~p"/admin/auth/oidc")
      else
        render(conn, :login,
          error: has_error,
          username: nil,
          oidc_enabled: OIDC.enabled?(),
          oidc_provider_name: OIDC.provider_name(),
          local_auth_enabled: OIDC.local_auth_enabled?()
        )
      end
    end
  end

  def do_login(conn, %{"username" => username, "password" => password} = params) do
    # Check if local auth is enabled
    unless OIDC.local_auth_enabled?() do
      conn
      |> render(:login,
        error: "Local authentication is disabled",
        username: nil,
        oidc_enabled: OIDC.enabled?(),
        oidc_provider_name: OIDC.provider_name(),
        local_auth_enabled: false
      )
    else
      totp_code = Map.get(params, "totp_code")

      # Check rate limit first
      case RateLimiter.check_rate(username) do
        {:error, seconds_remaining} ->
          conn
          |> render(:login,
            error: "Too many login attempts. Please try again in #{seconds_remaining} seconds.",
            username: username,
            oidc_enabled: OIDC.enabled?(),
            oidc_provider_name: OIDC.provider_name(),
            local_auth_enabled: OIDC.local_auth_enabled?()
          )

        :ok ->
          with {:ok, _} <- InputValidation.validate_username(username),
               {:ok, user} <- Authentication.authenticate(username, password, totp_code) do
            # Clear rate limit on successful login
            RateLimiter.clear(username)
            Log.info("auth.login.success", username: username, method: "local")
            Log.emit(:auth_login, %{count: 1}, %{method: "local", success: true})

            conn
            |> configure_session(renew: true)
            |> put_session(:admin_user_id, user.id)
            |> put_session(:admin_username, user.username)
            |> redirect(to: ~p"/admin")
          else
            {:error, msg} ->
              # Record failed attempt
              RateLimiter.record_failure(username)
              Log.warning("auth.login.failed", username: username, reason: msg)
              Log.emit(:auth_login, %{count: 1}, %{method: "local", success: false})

              conn
              |> render(:login,
                error: msg,
                username: username,
                oidc_enabled: OIDC.enabled?(),
                oidc_provider_name: OIDC.provider_name(),
                local_auth_enabled: OIDC.local_auth_enabled?()
              )
          end
      end
    end
  end

  # =============================================================================
  # OIDC Authentication
  # =============================================================================

  def oidc_login(conn, _params) do
    unless OIDC.enabled?() do
      conn
      |> put_flash(:error, "OIDC authentication is not enabled")
      |> redirect(to: ~p"/admin/login")
    else
      case OIDC.authorization_url() do
        {:ok, url, state, nonce} ->
          conn
          |> put_session(:oidc_state, state)
          |> put_session(:oidc_nonce, nonce)
          |> redirect(external: url)

        {:error, reason} ->
          conn
          |> put_flash(:error, "Failed to initiate SSO: #{reason}")
          |> redirect(to: ~p"/admin/login")
      end
    end
  end

  def oidc_callback(conn, %{"code" => code, "state" => state}) do
    stored_state = get_session(conn, :oidc_state)
    stored_nonce = get_session(conn, :oidc_nonce)

    case OIDC.callback(code, state, stored_state, stored_nonce) do
      {:ok, user_info} ->
        # Create a session identifier based on OIDC subject
        session_id = "oidc:#{user_info.sub}"

        Log.info("auth.login.success",
          username: user_info.name || user_info.email,
          method: "oidc"
        )

        Log.emit(:auth_login, %{count: 1}, %{method: "oidc", success: true})

        conn
        |> configure_session(renew: true)
        |> delete_session(:oidc_state)
        |> delete_session(:oidc_nonce)
        |> put_session(:admin_user_id, session_id)
        |> put_session(:admin_username, user_info.name || user_info.email)
        |> put_session(:auth_method, :oidc)
        |> redirect(to: ~p"/admin")

      {:error, reason} ->
        Log.warning("auth.oidc.callback_failed", reason: reason)

        conn
        |> delete_session(:oidc_state)
        |> delete_session(:oidc_nonce)
        |> put_flash(:error, reason)
        |> redirect(to: ~p"/admin/login")
    end
  end

  def oidc_callback(conn, %{"error" => error} = params) do
    error_description = Map.get(params, "error_description", error)

    conn
    |> delete_session(:oidc_state)
    |> delete_session(:oidc_nonce)
    |> put_flash(:error, "SSO error: #{error_description}")
    |> redirect(to: ~p"/admin/login")
  end

  def logout(conn, _params) do
    username = get_session(conn, :admin_username)
    Log.info("auth.logout", username: username)

    conn
    |> clear_session()
    |> redirect(to: ~p"/admin/login")
  end

  # =============================================================================
  # Places CRUD
  # =============================================================================

  def create(conn, _params) do
    render(conn, :create, changeset: nil, errors: [])
  end

  def do_create(conn, %{"place" => place_params}) do
    name = Map.get(place_params, "name", "")
    location = Map.get(place_params, "location", "")
    country = Map.get(place_params, "country", "")
    start_date = Map.get(place_params, "start_date", "")
    end_date = Map.get(place_params, "end_date")

    case InputValidation.validate_place_form(name, location, country, start_date, end_date) do
      {:error, errors} ->
        render(conn, :create, changeset: nil, errors: errors)

      {:ok, {valid_name, valid_location, valid_country, valid_start_date, valid_end_date}} ->
        attrs = %{
          name: valid_name,
          location: valid_location,
          country: valid_country,
          start_date: valid_start_date,
          end_date: valid_end_date
        }

        case Exposure.create_place(attrs) do
          {:ok, place} ->
            Exposure.invalidate_places_cache()
            Log.info("admin.place.created", place_id: place.id, name: valid_name)
            Log.emit(:place_create, %{count: 1}, %{place_id: place.id})
            redirect(conn, to: ~p"/admin/edit/#{place.id}")

          {:error, changeset} ->
            conn
            |> render(:create, changeset: changeset, errors: [])
        end
    end
  end

  def edit(conn, %{"id" => id}) do
    with {:ok, valid_id} <- safe_parse_integer(id, "Place ID"),
         place when not is_nil(place) <- Exposure.get_place(valid_id) do
      render(conn, :edit, place: place, errors: [])
    else
      {:error, _msg} ->
        conn
        |> put_status(:bad_request)
        |> put_view(html: ExposureWeb.ErrorHTML)
        |> render(:"404")

      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(html: ExposureWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  def update(conn, %{"id" => id, "place" => place_params}) do
    with {:ok, valid_id} <- safe_parse_integer(id, "Place ID"),
         {:ok, valid_id} <- InputValidation.validate_id(valid_id, "Place ID"),
         place when not is_nil(place) <- Exposure.get_place(valid_id) do
      name = Map.get(place_params, "name", "")
      location = Map.get(place_params, "location", "")
      country = Map.get(place_params, "country", "")
      start_date = Map.get(place_params, "start_date", "")
      end_date = Map.get(place_params, "end_date")

      case InputValidation.validate_place_form(
             name,
             location,
             country,
             start_date,
             end_date
           ) do
        {:error, errors} ->
          render(conn, :edit, place: place, errors: errors)

        {:ok, {valid_name, valid_location, valid_country, valid_start_date, valid_end_date}} ->
          attrs = %{
            name: valid_name,
            location: valid_location,
            country: valid_country,
            start_date: valid_start_date,
            end_date: valid_end_date
          }

          case Exposure.update_place(place, attrs) do
            {:ok, updated_place} ->
              Exposure.invalidate_places_cache()
              Log.info("admin.place.updated", place_id: updated_place.id)
              redirect(conn, to: ~p"/admin")

            {:error, _changeset} ->
              conn
              |> render(:edit, place: place, errors: ["Failed to update place"])
          end
      end
    else
      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, message: msg})

      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(html: ExposureWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, valid_id} <- safe_parse_integer(id, "Place ID"),
         {:ok, valid_id} <- InputValidation.validate_id(valid_id, "Place ID") do
      if Photo.delete_place_with_photos(valid_id) do
        Exposure.invalidate_places_cache()
        Log.info("admin.place.deleted", place_id: valid_id)
        Log.emit(:place_delete, %{count: 1}, %{place_id: valid_id})
        json(conn, %{success: true, message: "Place deleted successfully"})
      else
        conn
        |> put_status(:not_found)
        |> json(%{success: false, message: "Place not found"})
      end
    else
      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, message: msg})
    end
  end

  def reorder_places(conn, %{"order" => order}) do
    # Handle both list and map formats (FormData sends order[0], order[1] as a map)
    order_list =
      cond do
        is_list(order) ->
          order

        is_map(order) ->
          order
          |> Enum.sort_by(fn {k, _v} -> safe_integer_for_sort(k) end)
          |> Enum.map(fn {_k, v} -> v end)

        true ->
          []
      end

    if order_list == [] do
      conn
      |> put_status(:bad_request)
      |> json(%{success: false, message: "No order provided"})
    else
      case validate_order_list(order_list) do
        {:error, msg} ->
          conn
          |> put_status(:bad_request)
          |> json(%{success: false, message: msg})

        {:ok, validated_order} ->
          Exposure.reorder_places(validated_order)
          Exposure.invalidate_places_cache()
          Log.info("admin.places.reordered", count: length(validated_order))
          json(conn, %{success: true, message: "Places reordered successfully"})
      end
    end
  end

  # =============================================================================
  # Photos Management
  # =============================================================================

  def photos(conn, %{"id" => id}) do
    with {:ok, valid_id} <- safe_parse_integer(id, "Place ID"),
         place when not is_nil(place) <- Exposure.get_place(valid_id) do
      photos =
        place.photos
        |> Enum.sort_by(& &1.photo_num)
        |> Enum.map(fn ph ->
          %{
            num: ph.photo_num,
            slug: ph.slug,
            file_name: ph.file_name,
            is_favorite: ph.is_favorite
          }
        end)

      render(conn, :photos,
        place: %{
          id: place.id,
          name: place.name,
          location: place.location,
          country: place.country
        },
        total_photos: length(place.photos),
        photos: photos
      )
    else
      {:error, _msg} ->
        conn
        |> put_status(:bad_request)
        |> put_view(html: ExposureWeb.ErrorHTML)
        |> render(:"404")

      nil ->
        conn
        |> put_status(:not_found)
        |> put_view(html: ExposureWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  def upload_photos(conn, %{"place_id" => place_id, "files" => files}) do
    with {:ok, valid_id} <- safe_parse_integer(place_id, "Place ID"),
         {:ok, valid_id} <- InputValidation.validate_id(valid_id, "Place ID") do
      file_list = if is_list(files), do: files, else: [files]

      if file_list == [] do
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, message: "No files uploaded"})
      else
        case Photo.upload_photos(valid_id, file_list) do
          {:ok, count} ->
            Exposure.invalidate_places_cache()
            json(conn, %{success: true, message: "Uploaded #{count} photo(s)", count: count})

          {:error, msg} ->
            conn
            |> put_status(:bad_request)
            |> json(%{success: false, message: msg})
        end
      end
    else
      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, message: msg})
    end
  end

  def delete_photo(conn, %{"place_id" => place_id, "photo_num" => photo_num}) do
    with {:ok, valid_place_id} <- safe_parse_integer(place_id, "Place ID"),
         {:ok, valid_photo_num} <- safe_parse_integer(photo_num, "Photo number"),
         {:ok, valid_place_id} <- InputValidation.validate_id(valid_place_id, "Place ID"),
         {:ok, valid_photo_num} <- InputValidation.validate_id(valid_photo_num, "Photo number") do
      if Photo.delete_photo(valid_place_id, valid_photo_num) do
        Exposure.invalidate_places_cache()
        Log.info("admin.photo.deleted", place_id: valid_place_id, photo_num: valid_photo_num)
        json(conn, %{success: true, message: "Photo deleted successfully"})
      else
        conn
        |> put_status(:not_found)
        |> json(%{success: false, message: "Photo not found"})
      end
    else
      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, message: msg})
    end
  end

  def reorder_photos(conn, %{"place_id" => place_id, "order" => order}) do
    # Handle both list and map formats (FormData sends order[0], order[1] as a map)
    order_list =
      cond do
        is_list(order) ->
          order

        is_map(order) ->
          order
          |> Enum.sort_by(fn {k, _v} -> safe_integer_for_sort(k) end)
          |> Enum.map(fn {_k, v} -> v end)

        true ->
          []
      end

    with {:ok, valid_place_id} <- safe_parse_integer(place_id, "Place ID"),
         {:ok, valid_place_id} <- InputValidation.validate_id(valid_place_id, "Place ID") do
      if order_list == [] do
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, message: "No order provided"})
      else
        case validate_order_list(order_list) do
          {:error, msg} ->
            conn
            |> put_status(:bad_request)
            |> json(%{success: false, message: msg})

          {:ok, validated_order} ->
            if Photo.reorder_photos(valid_place_id, validated_order) do
              Log.info("admin.photos.reordered",
                place_id: valid_place_id,
                count: length(validated_order)
              )

              json(conn, %{success: true, message: "Photos reordered successfully"})
            else
              conn
              |> put_status(:bad_request)
              |> json(%{success: false, message: "Failed to reorder photos"})
            end
        end
      end
    else
      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, message: msg})
    end
  end

  def set_favorite(conn, %{
        "place_id" => place_id,
        "photo_num" => photo_num,
        "is_favorite" => is_favorite
      }) do
    is_favorite = is_favorite == "true" or is_favorite == true

    with {:ok, valid_place_id} <- safe_parse_integer(place_id, "Place ID"),
         {:ok, valid_photo_num} <- safe_parse_integer(photo_num, "Photo number"),
         {:ok, valid_place_id} <- InputValidation.validate_id(valid_place_id, "Place ID"),
         {:ok, valid_photo_num} <- InputValidation.validate_id(valid_photo_num, "Photo number") do
      if Photo.set_favorite(valid_place_id, valid_photo_num, is_favorite) do
        Exposure.invalidate_places_cache()
        message = if is_favorite, do: "Photo set as favorite", else: "Favorite removed"
        json(conn, %{success: true, message: message})
      else
        conn
        |> put_status(:not_found)
        |> json(%{success: false, message: "Photo not found"})
      end
    else
      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, message: msg})
    end
  end

  # =============================================================================
  # TOTP Management
  # =============================================================================

  def totp_setup(conn, _params) do
    username = get_session(conn, :admin_username)

    case Authentication.enable_totp(username) do
      {:ok, secret} ->
        qr_code_bytes = Authentication.generate_totp_qr_code(username, secret, "Exposure")
        qr_code_base64 = Base.encode64(qr_code_bytes)

        conn
        |> render(:totp_setup, totp_secret: secret, qr_code: qr_code_base64)

      {:error, msg} ->
        conn
        |> put_flash(:error, msg)
        |> redirect(to: ~p"/admin")
    end
  end

  def verify_totp(conn, %{"code" => code}) do
    case InputValidation.validate_totp_code(code) do
      {:error, msg} ->
        conn
        |> put_flash(:error, msg)
        |> redirect(to: ~p"/admin/totp-setup")

      {:ok, valid_code} ->
        username = get_session(conn, :admin_username)

        case Authentication.get_admin_user(username) do
          nil ->
            conn
            |> put_flash(:error, "User not found")
            |> redirect(to: ~p"/admin")

          user when not is_nil(user.totp_secret) ->
            if Authentication.verify_totp_code(user.totp_secret, valid_code) do
              conn
              |> put_flash(:info, "Two-factor authentication enabled successfully!")
              |> redirect(to: ~p"/admin")
            else
              conn
              |> put_flash(:error, "Invalid code. Please try again.")
              |> redirect(to: ~p"/admin/totp-setup")
            end

          _ ->
            conn
            |> put_flash(:error, "TOTP setup not found.")
            |> redirect(to: ~p"/admin")
        end
    end
  end

  def disable_totp(conn, _params) do
    username = get_session(conn, :admin_username)

    if Authentication.disable_totp(username) do
      conn
      |> put_flash(:info, "Two-factor authentication disabled.")
      |> redirect(to: ~p"/admin")
    else
      conn
      |> put_flash(:error, "Failed to disable two-factor authentication.")
      |> redirect(to: ~p"/admin")
    end
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp require_auth(conn, _opts) do
    if get_session(conn, :admin_user_id) do
      conn
    else
      conn
      |> redirect(to: ~p"/admin/login")
      |> halt()
    end
  end

  # Safe integer parsing for sorting (returns 0 on failure to avoid crashes)
  defp safe_integer_for_sort(value) when is_integer(value), do: value

  defp safe_integer_for_sort(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> 0
    end
  end

  defp safe_integer_for_sort(_), do: 0

  defp validate_order_list(order_list) do
    results =
      Enum.map(order_list, fn id ->
        with {:ok, int_id} <- safe_parse_integer(id, "Order value"),
             {:ok, validated_id} <- InputValidation.validate_id(int_id, "Order value") do
          {:ok, validated_id}
        end
      end)

    case Enum.find(results, fn result -> match?({:error, _}, result) end) do
      {:error, msg} -> {:error, msg}
      nil -> {:ok, Enum.map(results, fn {:ok, id} -> id end)}
    end
  end
end
