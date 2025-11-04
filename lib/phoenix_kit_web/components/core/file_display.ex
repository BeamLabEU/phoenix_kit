defmodule PhoenixKitWeb.Components.Core.FileDisplay do
  @moduledoc """
  Components for displaying file-related information.

  Provides status badges, file size formatting, and modification time display.
  """
  use Phoenix.Component

  @doc """
  Displays a status badge for pages.

  ## Examples

      <.page_status_badge status="published" />
      <.page_status_badge status="draft" />
      <.page_status_badge status="archived" />
  """
  attr :status, :string, required: true
  attr :class, :string, default: ""

  def page_status_badge(assigns) do
    ~H"""
    <span class={"badge badge-xs #{badge_class(@status)} #{@class}"}>
      {@status}
    </span>
    """
  end

  @doc """
  Displays formatted file size with automatic unit conversion.

  Handles nil values by returning "Unknown".
  Converts to GB, MB, KB, or bytes based on size.

  ## Examples

      <.file_size bytes={1024} />  <%!-- 1.0 KB --%>
      <.file_size bytes={1_048_576} />  <%!-- 1.0 MB --%>
      <.file_size bytes={5_242_880} />  <%!-- 5.0 MB --%>
      <.file_size bytes={nil} />  <%!-- Unknown --%>
  """
  attr :bytes, :integer, default: nil
  attr :class, :string, default: ""

  def file_size(assigns) do
    ~H"""
    <span class={@class}>{format_bytes(@bytes)}</span>
    """
  end

  @doc """
  Displays formatted modification time (relative or absolute).

  ## Examples

      <.file_mtime mtime={~N[2025-01-15 10:00:00]} />
  """
  attr :mtime, :any, required: true
  attr :class, :string, default: ""

  def file_mtime(assigns) do
    ~H"""
    <span class={@class}>Modified: {format_mtime(@mtime)}</span>
    """
  end

  # Private helpers

  defp badge_class(status) do
    case status do
      "published" -> "badge-success"
      "draft" -> "badge-warning"
      "archived" -> "badge-ghost"
      _ -> "badge-ghost"
    end
  end

  defp format_bytes(nil), do: "Unknown"

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} bytes"
    end
  end

  defp format_bytes(_), do: "Unknown"

  defp format_mtime(mtime) when is_tuple(mtime) do
    # Convert Erlang datetime tuple to NaiveDateTime
    case NaiveDateTime.from_erl(mtime) do
      {:ok, naive_dt} ->
        # Format as relative time or absolute
        now = NaiveDateTime.utc_now()
        diff_seconds = NaiveDateTime.diff(now, naive_dt)

        cond do
          diff_seconds < 60 -> "just now"
          diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
          diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)}h ago"
          diff_seconds < 604_800 -> "#{div(diff_seconds, 86_400)}d ago"
          true -> Calendar.strftime(naive_dt, "%Y-%m-%d")
        end

      {:error, _} ->
        "unknown"
    end
  end

  defp format_mtime(_), do: "unknown"
end
