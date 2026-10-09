defmodule PhoenixKitWeb.Components.Core.FileExifPanel do
  @moduledoc """
  A photo's EXIF, for the viewer's sidebar and the admin detail page: the camera,
  exposure, dates and GPS position worth keeping (`Storage.Exif.summary/1`, in the
  file's `metadata["exif"]`), and a way to look at the whole dump.

    * A photo whose EXIF was never read (one uploaded before it was kept) shows a
      **Read EXIF** button; reading records the summary and the position.
    * A photo with EXIF shows its groups, **All EXIF** (every tag the original
      carries, grouped, read on request and not stored) and **Read again**.
    * A photo that was read and had none says so.

  Nothing here writes: the buttons send `read_exif`, `show_exif` and `hide_exif`
  to the host (`target`), which decides who may. A host must not show this panel
  to anyone who may not see where a photo was taken.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.Modules.Storage.Exif

  attr :id, :string, required: true
  attr :exif, :any, default: nil, doc: "the file's `metadata[\"exif\"]`: nil when never read"
  attr :latitude, :any, default: nil
  attr :longitude, :any, default: nil

  attr :tags, :any,
    default: nil,
    doc: "every tag of the original (`Storage.exif_tags/1`) while the whole dump is open"

  attr :status, :atom, default: nil, values: [nil, :reading, :error]
  attr :can_read, :boolean, default: false, doc: "whether the buttons that record are offered"
  attr :target, :any, default: nil, doc: "the `phx-target` of the buttons"

  def file_exif_panel(assigns) do
    assigns = assign(assigns, :groups, summary_groups(assigns.exif))

    ~H"""
    <div id={@id} class="space-y-3 text-sm">
      <%!-- Never read: offer to. --%>
      <div :if={is_nil(@exif)} class="flex items-center gap-2">
        <span class="text-base-content/60">{gettext("EXIF has not been read yet.")}</span>
        <button
          :if={@can_read}
          type="button"
          phx-click="read_exif"
          phx-target={@target}
          disabled={@status == :reading}
          class="btn btn-ghost btn-xs"
        >
          <.icon name="hero-camera" class="w-3.5 h-3.5" /> {gettext("Read EXIF")}
        </button>
      </div>

      <%!-- Read, and there was nothing. --%>
      <p :if={@exif == %{}} class="text-base-content/60">
        {gettext("This photo carries no EXIF.")}
      </p>

      <div :for={{title, rows} <- @groups} class="space-y-1">
        <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">{title}</h4>
        <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5">
          <%= for {label, value} <- rows do %>
            <dt class="text-base-content/60">{label}</dt>
            <dd class="break-words">{value}</dd>
          <% end %>
        </dl>
      </div>

      <a
        :if={map_link(@latitude, @longitude)}
        href={map_link(@latitude, @longitude)}
        target="_blank"
        rel="noopener noreferrer"
        class="link link-primary text-xs inline-flex items-center gap-1"
      >
        <.icon name="hero-map-pin" class="w-3.5 h-3.5" /> {gettext("Show on a map")}
      </a>

      <div :if={@exif not in [nil, %{}]} class="flex flex-wrap items-center gap-2">
        <button
          type="button"
          phx-click={if @tags, do: "hide_exif", else: "show_exif"}
          phx-target={@target}
          disabled={@status == :reading}
          class="btn btn-ghost btn-xs"
        >
          <.icon name="hero-list-bullet" class="w-3.5 h-3.5" />
          {if @tags, do: gettext("Hide all EXIF"), else: gettext("All EXIF")}
        </button>
        <button
          :if={@can_read}
          type="button"
          phx-click="read_exif"
          phx-target={@target}
          disabled={@status == :reading}
          class="btn btn-ghost btn-xs"
        >
          <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> {gettext("Read again")}
        </button>
      </div>

      <p :if={@status == :error} class="text-xs text-error">
        {gettext("Could not read the EXIF of this photo.")}
      </p>

      <%!-- The whole dump, grouped. --%>
      <div :if={@tags} id={@id <> "-all"} class="space-y-3 border-t border-base-300 pt-3">
        <p :if={@tags == %{}} class="text-base-content/60">
          {gettext("This photo carries no EXIF.")}
        </p>
        <div :for={{group, rows} <- Exif.groups(@tags || %{})} class="space-y-1">
          <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
            {group_title(group)}
          </h4>
          <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 text-xs">
            <%= for {label, value} <- rows do %>
              <dt class="text-base-content/60">{label}</dt>
              <dd class="break-words font-mono">{value}</dd>
            <% end %>
          </dl>
        </div>
      </div>
    </div>
    """
  end

  @doc "The groups of a summary as `[{title, [{label, value}]}]`: what the panel prints."
  @spec summary_groups(map() | nil) :: [{String.t(), [{String.t(), String.t()}]}]
  def summary_groups(exif) when is_map(exif) do
    [
      {gettext("Camera"), camera_rows(exif["camera"])},
      {gettext("Exposure"), exposure_rows(exif["exposure"])},
      {gettext("Dates"), date_rows(exif["dates"])},
      {gettext("Location"), gps_rows(exif["gps"])}
    ]
    |> Enum.reject(fn {_title, rows} -> rows == [] end)
  end

  def summary_groups(_), do: []

  defp camera_rows(nil), do: []

  defp camera_rows(camera) do
    rows([
      {gettext("Camera"), join([camera["make"], camera["model"]])},
      {gettext("Lens"), camera["lens_model"]},
      {gettext("Software"), camera["software"]}
    ])
  end

  defp exposure_rows(nil), do: []

  defp exposure_rows(e) do
    rows([
      {gettext("Focal length"), focal_length(e["focal_length"], e["focal_length_35mm"])},
      {gettext("Aperture"), e["f_number"] && "ƒ/#{trim(e["f_number"])}"},
      {gettext("Shutter"), e["exposure_time"] && "#{e["exposure_time"]} s"},
      {gettext("ISO"), e["iso"]},
      {gettext("Flash"), flash(e["flash"])}
    ])
  end

  defp date_rows(nil), do: []

  defp date_rows(d) do
    offset = d["offset"]

    rows([
      {gettext("Taken"), local(d["original"], offset)},
      {gettext("Created"), local(d["digitized"], offset)},
      {gettext("Modified"), local(d["modified"], offset)}
    ])
  end

  defp gps_rows(nil), do: []

  defp gps_rows(g) do
    rows([
      {gettext("Latitude"), g["latitude"] && "#{g["latitude"]}°"},
      {gettext("Longitude"), g["longitude"] && "#{g["longitude"]}°"},
      {gettext("Altitude"), g["altitude"] && "#{trim(g["altitude"])} m"},
      {gettext("Direction"), direction(g["direction"], g["direction_ref"])},
      {gettext("Speed"), g["speed_kmh"] && "#{trim(g["speed_kmh"])} km/h"},
      {gettext("GPS time"), g["timestamp"] && String.replace(g["timestamp"], "T", " ")}
    ])
  end

  defp rows(pairs), do: for({label, value} <- pairs, value not in [nil, ""], do: {label, value})

  defp join(parts), do: parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")

  defp focal_length(nil, nil), do: nil
  defp focal_length(mm, nil), do: "#{trim(mm)} mm"
  defp focal_length(nil, equiv), do: "#{equiv} mm (35 mm)"
  defp focal_length(mm, equiv), do: "#{trim(mm)} mm (#{equiv} mm #{gettext("equivalent")})"

  defp flash(nil), do: nil
  defp flash(true), do: gettext("Fired")
  defp flash(false), do: gettext("Did not fire")

  defp direction(nil, _), do: nil
  defp direction(degrees, "true"), do: "#{trim(degrees)}° #{gettext("true north")}"
  defp direction(degrees, "magnetic"), do: "#{trim(degrees)}° #{gettext("magnetic")}"
  defp direction(degrees, _), do: "#{trim(degrees)}°"

  # "2026-10-05T18:42:46.907" + "+02:00" → "2026-10-05 18:42:46 (+02:00)".
  defp local(nil, _offset), do: nil

  defp local(value, offset) do
    text = value |> String.replace("T", " ") |> String.replace(~r/\.\d+$/, "")
    if offset, do: "#{text} (#{offset})", else: text
  end

  # 16.0 → "16", 2.8 → "2.8".
  defp trim(number) when is_float(number) do
    if number == Float.round(number, 0), do: Integer.to_string(trunc(number)), else: "#{number}"
  end

  defp trim(number), do: "#{number}"

  defp map_link(lat, lon) when is_number(lat) and is_number(lon) do
    "https://www.openstreetmap.org/?mlat=#{lat}&mlon=#{lon}#map=15/#{lat}/#{lon}"
  end

  defp map_link(_, _), do: nil

  defp group_title(group) do
    case group do
      :camera -> gettext("Camera")
      :exposure -> gettext("Exposure")
      :dates -> gettext("Dates")
      :location -> gettext("Location")
      :image -> gettext("Image")
      :other -> gettext("Other")
    end
  end
end
