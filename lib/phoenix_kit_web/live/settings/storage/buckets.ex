defmodule PhoenixKitWeb.Live.Settings.Storage.Buckets do
  @moduledoc """
  Storage buckets management LiveView.

  Provides interface for managing storage provider configurations (local, S3, B2, R2).
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Settings
  alias PhoenixKit.Storage
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load all buckets
    buckets = Storage.list_buckets()

    # Calculate usage stats for each bucket
    bucket_stats =
      Enum.map(buckets, fn bucket ->
        used_mb = Storage.calculate_bucket_usage(bucket.id)
        free_mb = Storage.calculate_bucket_free_space(bucket)

        %{
          bucket: bucket,
          used_mb: used_mb,
          free_mb: free_mb,
          usage_percent:
            if bucket.max_size_mb do
              round(used_mb / bucket.max_size_mb * 100)
            else
              nil
            end
        }
      end)

    socket =
      socket
      |> assign(:current_path, Routes.path("/admin/settings/storage/buckets"))
      |> assign(:page_title, "Storage Buckets")
      |> assign(:project_title, project_title)
      |> assign(:bucket_stats, bucket_stats)
      |> assign(:current_locale, locale)

    {:ok, socket}
  end

  def handle_event("delete_bucket", %{"id" => id}, socket) do
    bucket = Storage.get_bucket(id)

    case Storage.delete_bucket(bucket) do
      {:ok, _} ->
        # Reload buckets
        buckets = Storage.list_buckets()

        bucket_stats =
          Enum.map(buckets, fn bucket ->
            used_mb = Storage.calculate_bucket_usage(bucket.id)
            free_mb = Storage.calculate_bucket_free_space(bucket)

            %{
              bucket: bucket,
              used_mb: used_mb,
              free_mb: free_mb,
              usage_percent:
                if bucket.max_size_mb do
                  round(used_mb / bucket.max_size_mb * 100)
                else
                  nil
                end
            }
          end)

        socket =
          socket
          |> assign(:bucket_stats, bucket_stats)
          |> put_flash(:info, "Bucket deleted successfully")

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to delete bucket")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_bucket", %{"id" => id}, socket) do
    bucket = Storage.get_bucket(id)

    case Storage.update_bucket(bucket, %{enabled: !bucket.enabled}) do
      {:ok, _bucket} ->
        # Reload buckets
        buckets = Storage.list_buckets()

        bucket_stats =
          Enum.map(buckets, fn bucket ->
            used_mb = Storage.calculate_bucket_usage(bucket.id)
            free_mb = Storage.calculate_bucket_free_space(bucket)

            %{
              bucket: bucket,
              used_mb: used_mb,
              free_mb: free_mb,
              usage_percent:
                if bucket.max_size_mb do
                  round(used_mb / bucket.max_size_mb * 100)
                else
                  nil
                end
            }
          end)

        socket =
          socket
          |> assign(:bucket_stats, bucket_stats)
          |> put_flash(:info, "Bucket status updated")

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update bucket")
        {:noreply, socket}
    end
  end

  defp format_size(mb) when is_nil(mb), do: "Unlimited"
  defp format_size(mb) when mb > 1024, do: "#{Float.round(mb / 1024, 1)} GB"
  defp format_size(mb), do: "#{mb} MB"

  defp provider_badge_class("local"), do: "badge-success"
  defp provider_badge_class("s3"), do: "badge-warning"
  defp provider_badge_class("b2"), do: "badge-info"
  defp provider_badge_class("r2"), do: "badge-secondary"
  defp provider_badge_class(_), do: "badge-neutral"
end
