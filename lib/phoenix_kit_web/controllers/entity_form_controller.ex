defmodule PhoenixKitWeb.EntityFormController do
  @moduledoc """
  Controller for handling public entity form submissions.
  """
  use PhoenixKitWeb, :controller
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Entities
  alias PhoenixKit.Entities.EntityData

  @browser_patterns [
    {"Edg/", "Edge"},
    {"OPR/", "Opera"},
    {"Opera", "Opera"},
    {"Chrome/", "Chrome"},
    {"Safari/", "Safari"},
    {"Firefox/", "Firefox"},
    {"MSIE", "Internet Explorer"},
    {"Trident/", "Internet Explorer"}
  ]

  @os_patterns [
    {"Windows NT 10", "Windows 10"},
    {"Windows NT 6.3", "Windows 8.1"},
    {"Windows NT 6.2", "Windows 8"},
    {"Windows NT 6.1", "Windows 7"},
    {"Windows", "Windows"},
    {"Mac OS X", "macOS"},
    {"Macintosh", "macOS"},
    {"Linux", "Linux"},
    {"Android", "Android"},
    {"iPhone", "iOS"},
    {"iPad", "iOS"}
  ]

  @device_patterns [
    {"Mobile", "mobile"},
    {"Android", "mobile"},
    {"iPhone", "mobile"},
    {"iPad", "tablet"},
    {"Tablet", "tablet"}
  ]

  @doc """
  Handles public form submission for entities.
  """
  def submit(conn, %{"entity_slug" => entity_slug} = params) do
    entity = Entities.get_entity_by_name(entity_slug)

    cond do
      is_nil(entity) ->
        conn
        |> put_flash(:error, gettext("Entity not found"))
        |> redirect_back(conn)

      !public_form_enabled?(entity) ->
        conn
        |> put_flash(:error, gettext("Public form is not enabled for this entity"))
        |> redirect_back(conn)

      true ->
        handle_submission(conn, entity, params)
    end
  end

  defp handle_submission(conn, entity, params) do
    # Extract form data from params
    form_data = get_in(params, ["phoenix_kit_entity_data", "data"]) || %{}

    # Filter to only include allowed public form fields
    settings = entity.settings || %{}
    allowed_fields = Map.get(settings, "public_form_fields", [])

    filtered_data =
      form_data
      |> Enum.filter(fn {key, _value} -> key in allowed_fields end)
      |> Enum.into(%{})

    # Build entity data params
    # For public submissions, use the current user if logged in, otherwise use 0 (system)
    current_user = conn.assigns[:current_user]
    created_by = if current_user, do: current_user.id, else: 0
    title = generate_submission_title(entity, filtered_data)

    # Capture submission metadata
    metadata = build_submission_metadata(conn)

    entity_data_params = %{
      "entity_id" => entity.id,
      "title" => title,
      "slug" => generate_slug(title),
      "status" => "published",
      "data" => filtered_data,
      "metadata" => metadata,
      "created_by" => created_by
    }

    case EntityData.create(entity_data_params) do
      {:ok, _data_record} ->
        success_message =
          Map.get(
            settings,
            "public_form_success_message",
            gettext("Form submitted successfully!")
          )

        conn
        |> put_flash(:info, success_message)
        |> redirect_back(conn)

      {:error, _changeset} ->
        conn
        |> put_flash(:error, gettext("There was an error submitting the form. Please try again."))
        |> redirect_back(conn)
    end
  end

  defp public_form_enabled?(entity) do
    settings = entity.settings || %{}
    Map.get(settings, "public_form_enabled", false)
  end

  defp generate_submission_title(entity, data) do
    # Try to use a meaningful field value as title, or use entity display name
    title_candidates = ["name", "title", "subject", "email"]

    Enum.find_value(title_candidates, fn field ->
      value = Map.get(data, field)
      if value && value != "", do: value
    end) || entity.display_name
  end

  defp generate_slug(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.trim("-")
    |> Kernel.<>("-#{:rand.uniform(9999)}")
  end

  defp build_submission_metadata(conn) do
    user_agent = get_req_header(conn, "user-agent") |> List.first() || ""
    referer = get_req_header(conn, "referer") |> List.first()

    %{
      "source" => "public_form",
      "ip_address" => get_client_ip(conn),
      "user_agent" => user_agent,
      "browser" => parse_browser(user_agent),
      "os" => parse_os(user_agent),
      "device" => parse_device(user_agent),
      "referer" => referer,
      "submitted_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp get_client_ip(conn) do
    # Check for forwarded IP (behind proxy/load balancer)
    forwarded_for = get_req_header(conn, "x-forwarded-for") |> List.first()

    if forwarded_for do
      forwarded_for
      |> String.split(",")
      |> List.first()
      |> String.trim()
    else
      conn.remote_ip
      |> :inet.ntoa()
      |> to_string()
    end
  end

  defp parse_browser(user_agent) do
    Enum.find_value(@browser_patterns, "Unknown", fn {pattern, name} ->
      if String.contains?(user_agent, pattern), do: name
    end)
  end

  defp parse_os(user_agent) do
    Enum.find_value(@os_patterns, "Unknown", fn {pattern, name} ->
      if String.contains?(user_agent, pattern), do: name
    end)
  end

  defp parse_device(user_agent) do
    Enum.find_value(@device_patterns, "desktop", fn {pattern, type} ->
      if String.contains?(user_agent, pattern), do: type
    end)
  end

  defp redirect_back(conn, _fallback_conn) do
    referer = get_req_header(conn, "referer") |> List.first()

    if referer do
      redirect(conn, external: referer)
    else
      redirect(conn, to: "/")
    end
  end
end
