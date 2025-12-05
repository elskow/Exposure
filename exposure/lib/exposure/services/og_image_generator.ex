defmodule Exposure.Services.OgImageGenerator do
  @moduledoc """
  Generates "Minimalist Editorial" style Open Graph images.
  Focuses on the photography with clean, left-aligned typography.
  """

  require Logger

  @og_width 1200
  @og_height 630

  # Typography Settings
  @title_size 72
  @meta_size 20
  # Generous whitespace
  @padding 80

  # Home page OG settings
  @home_bg_color "#FCFCFA"
  @home_text_color "#111111"
  @home_accent_color "#9CA3AF"

  @doc """
  Gets the OG image filename for a given original filename.
  This is for individual photo OG images.
  """
  def get_og_filename(original_filename) do
    name_without_ext = Path.rootname(original_filename)
    "#{name_without_ext}-og.jpg"
  end

  @doc """
  Gets the place gallery OG image filename.
  Stored as "place-og.jpg" in the place's directory.
  """
  def get_place_og_filename do
    "place-og.jpg"
  end

  @doc """
  Gets the path where the home OG image should be stored.
  Uses PathValidation.wwwroot_path/0 for consistent path resolution.
  """
  def home_og_path do
    alias Exposure.Services.PathValidation
    Path.join([PathValidation.wwwroot_path(), "images", "home-og.jpg"])
  end

  @doc """
  Generates a typographic OG image for the home page.
  Editorial magazine-style design matching the home page aesthetic.
  """
  def generate_home_og(opts \\ []) do
    output_path = Keyword.get(opts, :output_path, home_og_path())
    place_count = Keyword.get(opts, :place_count, 0)

    font_dir = Application.app_dir(:exposure, "priv/static/fonts")

    fonts = %{
      title: Path.join(font_dir, "lora/lora-italic-500.ttf"),
      meta: Path.join(font_dir, "dm-mono/dm-mono-400.ttf"),
      serif: Path.join(font_dir, "lora/lora-400.ttf")
    }

    # Validate fonts exist
    with :ok <- validate_fonts_exist(fonts) do
      # Ensure output directory exists
      output_path |> Path.dirname() |> File.mkdir_p!()

      with {:ok, image} <- create_home_og_image(place_count, fonts) do
        write_atomic(image, output_path)
      end
    end
  end

  defp create_home_og_image(place_count, fonts) do
    # Create base canvas with warm off-white background
    svg_content = """
    <svg width="#{@og_width}" height="#{@og_height}" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <style>
          @font-face { font-family: 'TitleFont'; src: url('#{fonts.title}'); }
          @font-face { font-family: 'MetaFont'; src: url('#{fonts.meta}'); }
          @font-face { font-family: 'SerifFont'; src: url('#{fonts.serif}'); }
        </style>
      </defs>

      <!-- Background -->
      <rect width="100%" height="100%" fill="#{@home_bg_color}"/>

      <!-- Subtle border frame -->
      <rect x="40" y="40" width="#{@og_width - 80}" height="#{@og_height - 80}"
            fill="none" stroke="#{@home_accent_color}" stroke-width="0.5" opacity="0.3"/>

      <!-- Pin/Location icon at top -->
      <g transform="translate(#{@og_width / 2 - 12}, 100)">
        <path d="M12 0C5.4 0 0 5.4 0 12c0 9 12 18 12 18s12-9 12-18c0-6.6-5.4-12-12-12z"
              fill="none" stroke="#{@home_text_color}" stroke-width="0.8" opacity="0.6"/>
        <circle cx="12" cy="12" r="4" fill="#{@home_text_color}" opacity="0.6"/>
      </g>

      <!-- Main title: "Exposure" -->
      <text x="#{@og_width / 2}" y="#{@og_height / 2 - 30}"
            font-family="TitleFont" font-size="96" fill="#{@home_text_color}"
            text-anchor="middle" font-style="italic">
        Exposure
      </text>

      <!-- Tagline -->
      <text x="#{@og_width / 2}" y="#{@og_height / 2 + 30}"
            font-family="SerifFont" font-size="22" fill="#{@home_text_color}"
            text-anchor="middle" opacity="0.7">
        Places, frozen in time.
      </text>

      <!-- Bottom metadata line -->
      <g transform="translate(0, #{@og_height - 80})">
        <!-- Left: Author -->
        <text x="80" y="0"
              font-family="MetaFont" font-size="11" fill="#{@home_accent_color}"
              text-transform="uppercase" letter-spacing="1">
          HELMY LUQMANULHAKIM
        </text>

        <!-- Center: Place count -->
        <text x="#{@og_width / 2}" y="0"
              font-family="MetaFont" font-size="11" fill="#{@home_accent_color}"
              text-anchor="middle" letter-spacing="1">
          #{place_count} #{if place_count == 1, do: "DESTINATION", else: "DESTINATIONS"}
        </text>

        <!-- Right: Volume -->
        <text x="#{@og_width - 80}" y="0"
              font-family="MetaFont" font-size="11" fill="#{@home_accent_color}"
              text-anchor="end" letter-spacing="1">
          VOL. MMXXV
        </text>
      </g>

      <!-- Decorative line under tagline -->
      <line x1="#{@og_width / 2 - 60}" y1="#{@og_height / 2 + 55}"
            x2="#{@og_width / 2 + 60}" y2="#{@og_height / 2 + 55}"
            stroke="#{@home_text_color}" stroke-width="0.5" opacity="0.3"/>
    </svg>
    """

    Image.from_svg(svg_content)
  end

  @doc """
  Generates an OG image for a place page with photo background.
  """
  def generate(original_path, output_path, place_name, location, opts \\ []) do
    font_dir = Application.app_dir(:exposure, "priv/static/fonts")

    fonts = %{
      title: Keyword.get(opts, :title_font, Path.join(font_dir, "lora/lora-italic-500.ttf")),
      meta: Keyword.get(opts, :meta_font, Path.join(font_dir, "dm-mono/dm-mono-500.ttf"))
    }

    with :ok <- validate_fonts_exist(fonts),
         {:ok, image} <- Image.open(original_path, access: :random),
         # 1. Pure Geometry: Crop from CENTER
         {:ok, cropped} <- crop_to_og_ratio(image),

         # 2. Composition: Clean typography overlay
         {:ok, final} <- composite_minimalist_layer(cropped, place_name, location, fonts),
         {:ok, path} <- write_atomic(final, output_path) do
      Logger.info("Generated Minimalist OG: #{path}")
      {:ok, path}
    else
      {:error, reason} ->
        Logger.error("OG Generation Failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Generates a magazine cover style OG image for place gallery pages.
  Features a faded photo background with prominent centered typography.
  Updates: Supports multi-line word wrapping for titles.
  """
  def generate_place_og(original_path, output_path, opts) do
    place_name = Keyword.fetch!(opts, :place_name)
    location = Keyword.fetch!(opts, :location)
    country = Keyword.fetch!(opts, :country)
    photo_count = Keyword.get(opts, :photo_count, 0)
    trip_dates = Keyword.get(opts, :trip_dates, "")

    font_dir = Application.app_dir(:exposure, "priv/static/fonts")

    fonts = %{
      title: Path.join(font_dir, "lora/lora-italic-500.ttf"),
      meta: Path.join(font_dir, "dm-mono/dm-mono-400.ttf"),
      serif: Path.join(font_dir, "lora/lora-400.ttf")
    }

    with :ok <- validate_fonts_exist(fonts),
         {:ok, image} <- Image.open(original_path, access: :random),
         {:ok, cropped} <- crop_to_og_ratio(image),
         {:ok, final} <-
           composite_place_gallery_layer(
             cropped,
             place_name,
             location,
             country,
             photo_count,
             trip_dates,
             fonts
           ),
         {:ok, path} <- write_atomic(final, output_path) do
      Logger.info("Generated place gallery OG: #{path}")
      {:ok, path}
    else
      {:error, reason} ->
        Logger.error("Place gallery OG generation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Magazine cover style overlay for place gallery pages
  defp composite_place_gallery_layer(
         image,
         place_name,
         location,
         country,
         photo_count,
         trip_dates,
         fonts
       ) do
    {width, height, _} = Image.shape(image)

    # REPLACED: Simple truncation with intelligent word wrapping
    # Approx 18 chars per line works well for 84px font size
    title_lines = wrap_text(place_name, 18)

    # Calculate vertical offsets for perfect centering
    line_count = length(title_lines)
    line_height = 80 # Vertical space between lines
    total_text_height = (line_count - 1) * line_height
    # Start drawing text above center so the block is centered
    start_y = (height / 2) - (total_text_height / 2)

    location_text = "#{location}, #{country}"
    photo_text = "#{photo_count} #{if photo_count == 1, do: "PHOTO", else: "PHOTOS"}"

    # Generate the title SVG lines using <tspan>
    title_svg_lines =
      title_lines
      |> Enum.with_index()
      |> Enum.map(fn {line, index} ->
        # First line has no delta Y, subsequent lines push down by line_height
        dy = if index == 0, do: 0, else: line_height
        """
        <tspan x="#{width / 2}" dy="#{dy}">#{escape_svg(line)}</tspan>
        """
      end)
      |> Enum.join("\n")

    svg_overlay = """
    <svg width="#{width}" height="#{height}" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <style>
          @font-face { font-family: 'TitleFont'; src: url('#{fonts.title}'); }
          @font-face { font-family: 'MetaFont'; src: url('#{fonts.meta}'); }
          @font-face { font-family: 'SerifFont'; src: url('#{fonts.serif}'); }
        </style>

        <!-- Heavy overlay to fade the photo and create magazine cover feel -->
        <linearGradient id="magazineOverlay" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="black" stop-opacity="0.4"/>
          <stop offset="40%" stop-color="black" stop-opacity="0.3"/>
          <stop offset="70%" stop-color="black" stop-opacity="0.5"/>
          <stop offset="100%" stop-color="black" stop-opacity="0.7"/>
        </linearGradient>
      </defs>

      <!-- Dark overlay to fade photo -->
      <rect width="100%" height="100%" fill="url(#magazineOverlay)"/>

      <!-- Subtle border frame -->
      <rect x="40" y="40" width="#{width - 80}" height="#{height - 80}"
            fill="none" stroke="rgba(255,255,255,0.2)" stroke-width="0.5"/>

      <!-- Top left: "Exposure" brand -->
      <text x="80" y="90"
            font-family="TitleFont" font-size="28" fill="rgba(255,255,255,0.9)"
            font-style="italic">
        Exposure
      </text>

      <!-- Top right: Trip dates -->
      <text x="#{width - 80}" y="90"
            font-family="MetaFont" font-size="12" fill="rgba(255,255,255,0.8)"
            text-anchor="end" letter-spacing="2" font-weight="bold">
        #{escape_svg(String.upcase(trip_dates))}
      </text>

      <!-- Center: Main title (place name) -->
      <!-- We anchor to start_y, subsequent lines flow via dy -->
      <text x="#{width / 2}" y="#{start_y}"
            font-family="TitleFont" font-size="84" fill="white"
            text-anchor="middle" font-style="italic">
        #{title_svg_lines}
      </text>

      <!-- Below title: Location -->
      <!-- Position dependent on number of title lines -->
      <text x="#{width / 2}" y="#{start_y + (line_count * 50) + 40}"
            font-family="MetaFont" font-size="14" fill="rgba(255,255,255,0.9)"
            text-anchor="middle" letter-spacing="3" font-weight="bold">
        #{escape_svg(String.upcase(location_text))}
      </text>

      <!-- Decorative line -->
      <line x1="#{width / 2 - 40}" y1="#{start_y + (line_count * 50) + 70}"
            x2="#{width / 2 + 40}" y2="#{start_y + (line_count * 50) + 70}"
            stroke="rgba(255,255,255,0.5)" stroke-width="0.5"/>

      <!-- Bottom center: Photo count -->
      <text x="#{width / 2}" y="#{height - 60}"
            font-family="MetaFont" font-size="12" fill="rgba(255,255,255,0.7)"
            text-anchor="middle" letter-spacing="2">
        #{photo_text}
      </text>
    </svg>
    """

    with {:ok, overlay} <- Image.from_svg(svg_overlay),
         {:ok, composited} <- Image.compose(image, overlay) do
      {:ok, composited}
    end
  end

  # --- Helper Functions ---

  # Splitting text into multiple lines if they exceed max_chars
  defp wrap_text(text, max_chars) do
    text
    |> String.split(" ")
    |> Enum.reduce([], fn word, lines ->
      case lines do
        [] ->
          [word]
        [current_line | rest] ->
          # If adding the next word fits within the limit
          if String.length(current_line) + String.length(word) + 1 <= max_chars do
            ["#{current_line} #{word}" | rest]
          else
            # Otherwise start a new line
            [word, current_line | rest]
          end
      end
    end)
    |> Enum.reverse()
    # Limit to 3 lines max to prevent layout breaking
    |> Enum.take(3)
  end

  # --- Image Processing ---

  defp crop_to_og_ratio(image) do
    # crop: :center forces the crop to take the exact middle of the photo
    Image.thumbnail(image, @og_width, height: @og_height, crop: :center)
  end

  # --- Design Layout ---

  defp composite_minimalist_layer(image, title, location, fonts) do
    {width, height, _} = Image.shape(image)

    display_title = truncate_text(title, 25)
    # SVG doesn't support CSS text-transform, so we uppercase in Elixir
    display_location = String.upcase(location)

    # Calculate vertical positions relative to bottom padding
    # We stack from bottom: Brand -> Location -> Title
    brand_y = height - @padding
    location_y = brand_y - 35
    title_y = location_y - 35

    svg_overlay = """
    <svg width="#{width}" height="#{height}" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <style>
          @font-face { font-family: 'TitleFont'; src: url('#{fonts.title}'); }
          @font-face { font-family: 'MetaFont'; src: url('#{fonts.meta}'); }

          .title {
            font-family: 'TitleFont', serif;
            font-size: #{@title_size}px;
            fill: #FFFFFF;
          }

          .meta {
            font-family: 'MetaFont', monospace;
            font-size: #{@meta_size}px;
            fill: rgba(255, 255, 255, 0.85);
            letter-spacing: 1px;
          }
        </style>

        <linearGradient id="softBottom" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="black" stop-opacity="0"/>
          <stop offset="60%" stop-color="black" stop-opacity="0"/>
          <stop offset="100%" stop-color="black" stop-opacity="0.6"/>
        </linearGradient>
      </defs>

      <rect width="100%" height="100%" fill="url(#softBottom)"/>

      <g transform="translate(#{@padding}, 0)">

        <text x="0" y="#{title_y}" class="title">#{escape_svg(display_title)}</text>

        <text x="2" y="#{location_y}" class="meta">#{escape_svg(display_location)}</text>

        <text x="2" y="#{brand_y}" class="meta" style="opacity: 0.6;">EXPOSURE</text>

      </g>
    </svg>
    """

    with {:ok, overlay} <- Image.from_svg(svg_overlay),
         {:ok, composited} <- Image.compose(image, overlay) do
      {:ok, composited}
    end
  end

  defp truncate_text(nil, _max), do: ""
  defp truncate_text("", _max), do: ""

  defp truncate_text(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "...", else: text
  end

  defp escape_svg(nil), do: ""
  defp escape_svg(""), do: ""

  defp escape_svg(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  # Writes image to file atomically by writing to a temp file first,
  # then renaming. This prevents race conditions where a web request
  # could read a partially written file.
  #
  # Note: We keep the .jpg extension on the temp file because Image.write
  # uses the file extension to determine the output format.
  defp write_atomic(image, output_path) do
    # Generate temp path that preserves the .jpg extension
    # e.g., /path/to/home-og.jpg -> /path/to/home-og.tmp.55192.jpg
    dir = Path.dirname(output_path)
    basename = Path.basename(output_path, ".jpg")
    temp_path = Path.join(dir, "#{basename}.tmp.#{:rand.uniform(100_000)}.jpg")

    case Image.write(image, temp_path, quality: 95) do
      {:ok, _} ->
        case File.rename(temp_path, output_path) do
          :ok ->
            {:ok, output_path}

          {:error, reason} ->
            # Clean up temp file on rename failure
            File.rm(temp_path)
            Logger.error("Failed to rename OG image: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        # Clean up temp file on write failure
        File.rm(temp_path)
        Logger.error("Failed to write OG image: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Validates that all required font files exist
  defp validate_fonts_exist(fonts) do
    missing_fonts =
      fonts
      |> Enum.filter(fn {_name, path} -> not File.exists?(path) end)
      |> Enum.map(fn {name, path} -> "#{name}: #{path}" end)

    case missing_fonts do
      [] ->
        :ok

      missing ->
        Logger.error("Missing font files: #{Enum.join(missing, ", ")}")
        {:error, "Missing font files: #{Enum.join(missing, ", ")}"}
    end
  end
end
