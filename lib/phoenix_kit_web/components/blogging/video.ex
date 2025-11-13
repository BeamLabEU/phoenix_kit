defmodule PhoenixKitWeb.Components.Blogging.Video do
  @moduledoc """
  Responsive YouTube embed component.

  Supports both explicit `video_id` and full YouTube URLs.
  Optional attributes:
    * `autoplay` - "true" | "false" (default)
    * `muted` - "true" | "false" (default)
    * `controls` - "true" | "false" (default)
    * `loop` - "true" | "false" (default)
    * `start` - start time in seconds
    * `ratio` - aspect ratio string (e.g., "16:9", "4:3", "1:1")
  Component body text is rendered as a caption beneath the player.
  """
  use Phoenix.Component

  @standard_youtube_hosts [
    "youtube.com",
    "www.youtube.com",
    "m.youtube.com",
    "music.youtube.com"
  ]

  @short_youtube_hosts [
    "youtu.be"
  ]

  attr(:attributes, :map, default: %{})
  attr(:variant, :string, default: "default")
  attr(:content, :string, default: nil)

  def render(assigns) do
    attrs = assigns.attributes || %{}

    video_id =
      attrs
      |> Map.get("video_id")
      |> presence() || extract_video_id(Map.get(attrs, "url"))

    assigns =
      assigns
      |> assign(:video_id, video_id)
      |> assign(:embed_url, build_embed_url(video_id, attrs))
      |> assign(:aspect_ratio_class, ratio_class(Map.get(attrs, "ratio", "16:9")))
      |> assign(:has_caption?, has_caption?(assigns.content))
      |> assign(:caption, assigns.content)

    ~H"""
    <%= if @video_id do %>
      <div class="phk-video space-y-4">
        <div class={[
          "relative w-full overflow-hidden rounded-2xl shadow-xl bg-base-200",
          @aspect_ratio_class
        ]}>
          <iframe
            src={@embed_url}
            class="absolute inset-0 h-full w-full"
            title="YouTube video"
            allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
            allowfullscreen
            loading="lazy"
          >
          </iframe>
        </div>
        <%= if @has_caption? do %>
          <p class="text-sm text-base-content/70 text-center">
            {@caption}
          </p>
        <% end %>
      </div>
    <% else %>
      <div class="phk-video phk-video--invalid w-full rounded-xl border border-dashed border-error/40 bg-error/5 p-6 text-center text-sm text-error">
        Unable to load video – please supply a valid YouTube `video_id` or `url`.
      </div>
    <% end %>
    """
  end

  defp build_embed_url(nil, _attrs), do: nil

  defp build_embed_url(video_id, attrs) do
    base = "https://www.youtube.com/embed/#{video_id}"

    params =
      [
        {"autoplay", truthy?(Map.get(attrs, "autoplay"))},
        {"mute", truthy?(Map.get(attrs, "muted"))},
        {"controls", controls_value(Map.get(attrs, "controls"))},
        {"loop", truthy?(Map.get(attrs, "loop"))},
        {"start", parse_integer(Map.get(attrs, "start"))}
      ]
      |> Enum.reduce([], fn
        {"loop", true}, acc -> [{"loop", "1"}, {"playlist", video_id} | acc]
        {"loop", _}, acc -> acc
        {"autoplay", true}, acc -> [{"autoplay", "1"} | acc]
        {"autoplay", _}, acc -> acc
        {"mute", true}, acc -> [{"mute", "1"} | acc]
        {"mute", _}, acc -> acc
        {"controls", value}, acc when value in ["0", "1"] -> [{"controls", value} | acc]
        {"start", nil}, acc -> acc
        {"start", value}, acc -> [{"start", Integer.to_string(value)} | acc]
        _, acc -> acc
      end)
      |> Enum.reverse()

    if params == [] do
      base
    else
      base <> "?" <> URI.encode_query(params)
    end
  end

  defp ratio_class(ratio) do
    case ratio do
      "4:3" -> "aspect-[4/3]"
      "1:1" -> "aspect-square"
      "21:9" -> "aspect-[21/9]"
      _ -> "aspect-video"
    end
  end

  defp extract_video_id(nil), do: nil

  defp extract_video_id(url) when is_binary(url) do
    with trimmed when trimmed != "" <- String.trim(url),
         {:ok, uri} <- parse_uri(trimmed),
         {:ok, host_type} <- classify_host(uri.host) do
      case host_type do
        :short -> extract_short_id(uri.path)
        :standard -> extract_standard_id(uri)
      end
    else
      _ -> nil
    end
  end

  defp extract_video_id(_), do: nil

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp presence(_), do: nil

  defp truthy?(true), do: true
  defp truthy?(false), do: false

  defp truthy?(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()
    value in ["true", "1", "yes", "on"]
  end

  defp truthy?(value) when is_integer(value), do: value != 0
  defp truthy?(_), do: false

  defp controls_value(value) do
    if explicitly_false?(value), do: "0", else: "1"
  end

  defp explicitly_false?(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> false
      v -> v in ["false", "0", "no", "off"]
    end
  end

  defp explicitly_false?(false), do: true
  defp explicitly_false?(0), do: true
  defp explicitly_false?(_), do: false

  defp parse_integer(nil), do: nil

  defp parse_integer(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      number ->
        case Integer.parse(number) do
          {int, _} when int >= 0 -> int
          _ -> nil
        end
    end
  end

  defp parse_integer(value) when is_integer(value) and value >= 0, do: value
  defp parse_integer(_), do: nil

  defp has_caption?(value) when is_binary(value) do
    String.trim(value) != ""
  end

  defp has_caption?(_), do: false

  defp parse_uri(string) when is_binary(string) do
    case URI.parse(string) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, uri}

      _ ->
        :error
    end
  end

  defp parse_uri(_), do: :error

  defp classify_host(host) when is_binary(host) do
    host = String.downcase(host)

    cond do
      host in @short_youtube_hosts -> {:ok, :short}
      host in @standard_youtube_hosts -> {:ok, :standard}
      true -> :error
    end
  end

  defp classify_host(_), do: :error

  defp extract_short_id(nil), do: nil

  defp extract_short_id(path) do
    path
    |> String.trim_leading("/")
    |> String.split("/", trim: true)
    |> List.first()
  end

  defp extract_standard_id(%URI{path: path} = uri) do
    if is_binary(path) and String.starts_with?(path, "/embed/") do
      path
      |> String.split("/", trim: true)
      |> List.last()
    else
      uri.query
      |> decode_query()
      |> Map.get("v")
    end
  end

  defp decode_query(nil), do: %{}

  defp decode_query(query) do
    query
    |> URI.query_decoder()
    |> Enum.into(%{})
  end
end
