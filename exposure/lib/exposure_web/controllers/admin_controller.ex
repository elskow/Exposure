defmodule ExposureWeb.AdminController do
  use ExposureWeb, :controller

  alias Exposure.Gallery
  alias Exposure.Services.{Authentication, InputValidation, Photo}

  plug(:require_auth when action not in [:login, :do_login])

  # =============================================================================
  # Dashboard
  # =============================================================================

  def index(conn, _params) do
    places = Gallery.list_places()
    total_photos = Enum.sum(Enum.map(places, fn p -> length(p.photos) end))
    total_favorites = Gallery.total_favorites()

    place_summaries =
      Enum.map(places, fn place ->
        favorite_photo = Gallery.get_favorite_photo(place)

        %{
          id: place.id,
          name: place.name,
          location: place.location,
          country: place.country,
          photos: length(place.photos),
          trip_dates: Gallery.trip_dates_display(place.start_date, place.end_date),
          sort_order: place.sort_order,
          favorite_photo_num: favorite_photo && favorite_photo.photo_num,
          favorite_photo_file_name: favorite_photo && favorite_photo.file_name
        }
      end)

    conn
    |> put_root_layout(false)
    |> render(:index,
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
      conn
      |> put_root_layout(false)
      |> render(:login, error: nil, username: nil)
    end
  end

  def do_login(conn, %{"username" => username, "password" => password} = params) do
    totp_code = Map.get(params, "totp_code")

    with {:ok, _} <- InputValidation.validate_username(username),
         {:ok, user} <- Authentication.authenticate(username, password, totp_code) do
      conn
      |> put_session(:admin_user_id, user.id)
      |> put_session(:admin_username, user.username)
      |> redirect(to: ~p"/admin")
    else
      {:error, msg} ->
        conn
        |> put_root_layout(false)
        |> render(:login, error: msg, username: username)
    end
  end

  def logout(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: ~p"/admin/login")
  end

  # =============================================================================
  # Places CRUD
  # =============================================================================

  def create(conn, _params) do
    conn
    |> put_root_layout(false)
    |> render(:create, changeset: nil, errors: [])
  end

  def do_create(conn, %{"place" => place_params}) do
    name = Map.get(place_params, "name", "")
    location = Map.get(place_params, "location", "")
    country = Map.get(place_params, "country", "")
    start_date = Map.get(place_params, "start_date", "")
    end_date = Map.get(place_params, "end_date")

    case InputValidation.validate_place_form(name, location, country, start_date, end_date) do
      {:error, errors} ->
        conn
        |> put_root_layout(false)
        |> render(:create, changeset: nil, errors: errors)

      {:ok, {valid_name, valid_location, valid_country, valid_start_date, valid_end_date}} ->
        attrs = %{
          name: valid_name,
          location: valid_location,
          country: valid_country,
          start_date: valid_start_date,
          end_date: valid_end_date
        }

        case Gallery.create_place(attrs) do
          {:ok, place} ->
            redirect(conn, to: ~p"/admin/edit/#{place.id}")

          {:error, changeset} ->
            conn
            |> put_root_layout(false)
            |> render(:create, changeset: changeset, errors: [])
        end
    end
  end

  def edit(conn, %{"id" => id}) do
    id = String.to_integer(id)

    case Gallery.get_place(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_root_layout(false)
        |> put_view(html: ExposureWeb.ErrorHTML)
        |> render(:"404")

      place ->
        conn
        |> put_root_layout(false)
        |> render(:edit, place: place, errors: [])
    end
  end

  def update(conn, %{"id" => id, "place" => place_params}) do
    id = String.to_integer(id)

    case InputValidation.validate_id(id, "Place ID") do
      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, message: msg})

      {:ok, valid_id} ->
        case Gallery.get_place(valid_id) do
          nil ->
            conn
            |> put_status(:not_found)
            |> put_root_layout(false)
            |> put_view(html: ExposureWeb.ErrorHTML)
            |> render(:"404")

          place ->
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
                conn
                |> put_root_layout(false)
                |> render(:edit, place: place, errors: errors)

              {:ok, {valid_name, valid_location, valid_country, valid_start_date, valid_end_date}} ->
                attrs = %{
                  name: valid_name,
                  location: valid_location,
                  country: valid_country,
                  start_date: valid_start_date,
                  end_date: valid_end_date
                }

                case Gallery.update_place(place, attrs) do
                  {:ok, _} ->
                    redirect(conn, to: ~p"/admin")

                  {:error, _changeset} ->
                    conn
                    |> put_root_layout(false)
                    |> render(:edit, place: place, errors: ["Failed to update place"])
                end
            end
        end
    end
  end

  def delete(conn, %{"id" => id}) do
    id = String.to_integer(id)

    case InputValidation.validate_id(id, "Place ID") do
      {:error, msg} ->
        json(conn, %{success: false, message: msg})

      {:ok, valid_id} ->
        if Photo.delete_place_with_photos(valid_id) do
          json(conn, %{success: true, message: "Place deleted successfully"})
        else
          conn
          |> put_status(:not_found)
          |> json(%{success: false, message: "Place not found"})
        end
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
          |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
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

        :ok ->
          Gallery.reorder_places(order_list)
          json(conn, %{success: true, message: "Places reordered successfully"})
      end
    end
  end

  # =============================================================================
  # Photos Management
  # =============================================================================

  def photos(conn, %{"id" => id}) do
    id = String.to_integer(id)

    case Gallery.get_place(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> put_root_layout(false)
        |> put_view(html: ExposureWeb.ErrorHTML)
        |> render(:"404")

      place ->
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

        conn
        |> put_root_layout(false)
        |> render(:photos,
          place: %{
            id: place.id,
            name: place.name,
            location: place.location,
            country: place.country
          },
          total_photos: length(place.photos),
          photos: photos
        )
    end
  end

  def upload_photos(conn, %{"place_id" => place_id, "files" => files}) do
    place_id = String.to_integer(place_id)

    case InputValidation.validate_id(place_id, "Place ID") do
      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, message: msg})

      {:ok, valid_id} ->
        file_list = if is_list(files), do: files, else: [files]

        if file_list == [] do
          conn
          |> put_status(:bad_request)
          |> json(%{success: false, message: "No files uploaded"})
        else
          case Photo.upload_photos(valid_id, file_list) do
            {:ok, count} ->
              json(conn, %{success: true, message: "Uploaded #{count} photo(s)", count: count})

            {:error, msg} ->
              conn
              |> put_status(:bad_request)
              |> json(%{success: false, message: msg})
          end
        end
    end
  end

  def delete_photo(conn, %{"place_id" => place_id, "photo_num" => photo_num}) do
    place_id = String.to_integer(place_id)
    photo_num = String.to_integer(photo_num)

    with {:ok, valid_place_id} <- InputValidation.validate_id(place_id, "Place ID"),
         {:ok, valid_photo_num} <- InputValidation.validate_id(photo_num, "Photo number") do
      if Photo.delete_photo(valid_place_id, valid_photo_num) do
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
    place_id = String.to_integer(place_id)

    # Handle both list and map formats (FormData sends order[0], order[1] as a map)
    order_list =
      cond do
        is_list(order) ->
          order

        is_map(order) ->
          order
          |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
          |> Enum.map(fn {_k, v} -> v end)

        true ->
          []
      end

    case InputValidation.validate_id(place_id, "Place ID") do
      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, message: msg})

      {:ok, valid_place_id} ->
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

            :ok ->
              if Photo.reorder_photos(valid_place_id, order_list) do
                json(conn, %{success: true, message: "Photos reordered successfully"})
              else
                conn
                |> put_status(:bad_request)
                |> json(%{success: false, message: "Failed to reorder photos"})
              end
          end
        end
    end
  end

  def set_favorite(conn, %{
        "place_id" => place_id,
        "photo_num" => photo_num,
        "is_favorite" => is_favorite
      }) do
    place_id = String.to_integer(place_id)
    photo_num = String.to_integer(photo_num)
    is_favorite = is_favorite == "true" or is_favorite == true

    with {:ok, valid_place_id} <- InputValidation.validate_id(place_id, "Place ID"),
         {:ok, valid_photo_num} <- InputValidation.validate_id(photo_num, "Photo number") do
      if Photo.set_favorite(valid_place_id, valid_photo_num, is_favorite) do
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
        qr_code_bytes = Authentication.generate_totp_qr_code(username, secret, "Gallery Admin")
        qr_code_base64 = Base.encode64(qr_code_bytes)

        conn
        |> put_root_layout(false)
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

  defp validate_order_list(order_list) do
    invalid =
      order_list
      |> Enum.map(fn id ->
        id = if is_binary(id), do: String.to_integer(id), else: id
        InputValidation.validate_id(id, "Order value")
      end)
      |> Enum.find(fn result -> match?({:error, _}, result) end)

    case invalid do
      {:error, msg} -> {:error, msg}
      nil -> :ok
    end
  end
end
