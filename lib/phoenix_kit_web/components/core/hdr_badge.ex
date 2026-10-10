defmodule PhoenixKitWeb.Components.Core.HdrBadge do
  @moduledoc """
  A photo's HDR gain map, in a line: an `HDR` badge and what the file says about it
  (which descriptions it carries and its headroom). Renders nothing for a photo
  without one. The summary is `metadata["hdr"]` (`Storage.Hdr`).
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Storage.Hdr

  attr :hdr, :any, default: nil

  def hdr_badge(assigns) do
    ~H"""
    <span :if={Hdr.gain_map?(@hdr)} class="inline-flex flex-wrap items-center gap-1">
      <span class="badge badge-sm badge-primary">HDR</span>
      <span class="text-xs text-base-content/60">{detail(@hdr)}</span>
    </span>
    """
  end

  defp detail(hdr) do
    [
      gettext("gain map"),
      kinds(hdr["kinds"]),
      headroom(hdr["headroom"])
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp kinds(list) when is_list(list) and list != [],
    do: Enum.map_join(list, ", ", &kind_label/1)

  defp kinds(_), do: nil

  defp kind_label("apple"), do: "Apple"
  defp kind_label("iso21496"), do: "ISO 21496-1"
  defp kind_label("ultrahdr"), do: "Ultra HDR"
  defp kind_label(other), do: to_string(other)

  defp headroom(value) when is_number(value),
    do: gettext("headroom %{value}", value: :erlang.float_to_binary(value * 1.0, decimals: 2))

  defp headroom(_), do: nil
end
