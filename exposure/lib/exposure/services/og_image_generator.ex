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
  @padding 80 # Generous whitespace

  @doc """
  Gets the OG image filename for a given original filename.
  """
  def get_og_filename(original_filename) do
    name_without_ext = Path.rootname(original_filename)
    "#{name_without_ext}-og.jpg"
  end

  def generate(original_path, output_path, place_name, location, opts \\ []) do
    font_dir = Application.app_dir(:exposure, "priv/static/fonts")

    fonts = %{
      title: Keyword.get(opts, :title_font, Path.join(font_dir, "lora/lora-italic-500.ttf")),
      meta: Keyword.get(opts, :meta_font, Path.join(font_dir, "dm-mono/dm-mono-500.ttf"))
    }

    with {:ok, image} <- Image.open(original_path, access: :random),
         # 1. Pure Geometry: Crop from CENTER
         {:ok, cropped} <- crop_to_og_ratio(image),

         # 2. Composition: Clean typography overlay
         {:ok, final} <- composite_minimalist_layer(cropped, place_name, location, fonts),

         {:ok, _} <- Image.write(final, output_path, quality: 95) do
      Logger.info("Generated Minimalist OG: #{output_path}")
      {:ok, output_path}
    else
      {:error, reason} ->
        Logger.error("OG Generation Failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- Image Processing ---

  defp crop_to_og_ratio(image) do
    # CHANGED: crop: :center forces the crop to take the exact middle of the photo
    Image.thumbnail(image, @og_width, height: @og_height, crop: :center)
  end

  # --- Design Layout ---

  defp composite_minimalist_layer(image, title, location, fonts) do
    {width, height, _} = Image.shape(image)

    display_title = truncate_text(title, 25)

    # Calculate vertical positions relative to bottom padding
    # We stack from bottom: Brand -> Location -> Title
    brand_y = height - @padding
    location_y = brand_y - 35
    title_y = location_y - 35

    svg_overlay = """
    <svg width="#{width}" height="#{height}">
      <defs>
        <style>
          @font-face { font-family: 'TitleFont'; src: url('#{fonts.title}'); }
          @font-face { font-family: 'MetaFont'; src: url('#{fonts.meta}'); }

          /* Clean, crisp white text */
          .title {
            font-family: 'TitleFont', serif;
            font-size: #{@title_size}px;
            fill: #FFFFFF;
            /* Very subtle shadow just for readability, not style */
            text-shadow: 0 2px 10px rgba(0,0,0,0.3);
          }

          .meta {
            font-family: 'MetaFont', monospace;
            font-size: #{@meta_size}px;
            fill: rgba(255, 255, 255, 0.85);
            letter-spacing: 1px;
            text-transform: uppercase;
            text-shadow: 0 1px 4px rgba(0,0,0,0.4);
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

        <text x="2" y="#{location_y}" class="meta">#{escape_svg(location)}</text>

        <text x="2" y="#{brand_y}" class="meta" style="opacity: 0.6;">Exposure</text>

      </g>
    </svg>
    """

    with {:ok, overlay} <- Image.from_svg(svg_overlay),
         {:ok, composited} <- Image.compose(image, overlay) do
      {:ok, composited}
    end
  end

  defp truncate_text(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "...", else: text
  end

  defp escape_svg(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
