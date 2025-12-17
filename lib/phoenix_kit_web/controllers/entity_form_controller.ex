defmodule PhoenixKitWeb.EntityFormController do
  @moduledoc """
  Controller for handling public entity form submissions.
  """
  use PhoenixKitWeb, :controller
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Entities
  alias PhoenixKit.Entities.EntityData
  alias PhoenixKit.Users.RateLimiter

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

  # Minimum time in seconds for form submission (time-based validation)
  @min_submission_time 3

  # Rate limit: max submissions per IP
  @rate_limit_max 5
  @rate_limit_window_ms 60_000

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
        # Run security checks and collect any flags
        security_result = run_security_checks(conn, entity, params)
        handle_security_result(conn, entity, params, security_result)
    end
  end

  defp run_security_checks(conn, entity, params) do
    settings = entity.settings || %{}

    # Collect all security check results
    checks = [
      check_honeypot(settings, params),
      check_submission_time(settings, params),
      check_rate_limit(conn, settings, entity)
    ]

    # Find any triggered checks that require action
    triggered =
      checks
      |> Enum.filter(fn
        {:triggered, _type, _action} -> true
        _ -> false
      end)

    case triggered do
      [] -> :ok
      flags -> {:flagged, flags}
    end
  end

  defp handle_security_result(conn, entity, params, :ok) do
    handle_submission(conn, entity, params, [])
  end

  defp handle_security_result(conn, entity, params, {:flagged, flags}) do
    # Check if any flags require rejection
    reject_flags =
      Enum.filter(flags, fn {:triggered, _type, action} ->
        action in ["reject_silent", "reject_error"]
      end)

    save_flags =
      Enum.filter(flags, fn {:triggered, _type, action} ->
        action in ["save_suspicious", "save_log"]
      end)

    cond do
      # If any flag requires rejection
      not Enum.empty?(reject_flags) ->
        handle_rejection(conn, entity, reject_flags)

      # If flags only require saving with markers
      not Enum.empty?(save_flags) ->
        handle_submission(conn, entity, params, save_flags)

      # Fallback - should not happen
      true ->
        handle_submission(conn, entity, params, [])
    end
  end

  defp handle_rejection(conn, entity, reject_flags) do
    settings = entity.settings || %{}
    debug_mode = Map.get(settings, "public_form_debug_mode", false)

    # Track rejected submission
    increment_form_stats(entity, :rejected, reject_flags)

    # Check if any require error message (reject_error takes precedence)
    has_error =
      Enum.any?(reject_flags, fn {:triggered, _type, action} ->
        action == "reject_error"
      end)

    if has_error do
      # Get the first error type for the message
      {:triggered, error_type, _} = List.first(reject_flags)
      error_message = get_error_message(error_type, debug_mode)

      conn
      |> put_flash(:error, error_message)
      |> redirect_back(conn)
    else
      # Silent rejection - show fake success
      conn
      |> put_flash(:info, get_success_message(entity))
      |> redirect_back(conn)
    end
  end

  # Debug mode error messages (detailed)
  defp get_error_message(:honeypot, true),
    do: gettext("[Debug] Submission rejected: Honeypot field was filled.")

  defp get_error_message(:too_fast, true),
    do:
      gettext(
        "[Debug] Submission rejected: Form was submitted too quickly (less than 3 seconds)."
      )

  defp get_error_message(:rate_limited, true),
    do: gettext("[Debug] Submission rejected: Rate limit exceeded (5 submissions per minute).")

  defp get_error_message(type, true),
    do: gettext("[Debug] Submission rejected: Security check failed (%{type}).", type: type)

  # Normal error messages (generic)
  defp get_error_message(:honeypot, false), do: gettext("There was an error submitting the form.")

  defp get_error_message(:too_fast, false),
    do: gettext("Please take your time filling out the form.")

  defp get_error_message(:rate_limited, false),
    do: gettext("Too many submissions. Please try again later.")

  defp get_error_message(_, false), do: gettext("There was an error submitting the form.")

  defp check_honeypot(settings, params) do
    if Map.get(settings, "public_form_honeypot", false) do
      honeypot_value = Map.get(params, "_hp_website", "")

      if honeypot_value == "" do
        :ok
      else
        action = Map.get(settings, "public_form_honeypot_action", "reject_silent")
        {:triggered, :honeypot, action}
      end
    else
      :ok
    end
  end

  defp check_submission_time(settings, params) do
    if Map.get(settings, "public_form_time_check", false) do
      case get_time_to_submit(params) do
        nil ->
          # No timestamp provided, allow (could be form cached before feature enabled)
          :ok

        seconds when seconds >= @min_submission_time ->
          :ok

        _too_fast ->
          action = Map.get(settings, "public_form_time_check_action", "reject_error")
          {:triggered, :too_fast, action}
      end
    else
      :ok
    end
  end

  defp get_time_to_submit(params) do
    case Map.get(params, "_form_loaded_at") do
      nil ->
        nil

      loaded_at_str ->
        case DateTime.from_iso8601(loaded_at_str) do
          {:ok, loaded_at, _offset} ->
            DateTime.diff(DateTime.utc_now(), loaded_at, :second)

          _ ->
            nil
        end
    end
  end

  defp check_rate_limit(conn, settings, entity) do
    if Map.get(settings, "public_form_rate_limit", false) do
      ip = get_client_ip(conn)
      key = "entity_form:#{entity.id}:#{ip}"

      # Use the same Backend module used by RateLimiter
      case RateLimiter.Backend.hit(key, @rate_limit_window_ms, @rate_limit_max) do
        {:allow, _count} ->
          :ok

        {:deny, _retry_after} ->
          action = Map.get(settings, "public_form_rate_limit_action", "reject_error")
          {:triggered, :rate_limited, action}
      end
    else
      :ok
    end
  rescue
    # If Hammer is not available or not started, allow the request
    _ -> :ok
  end

  defp get_success_message(entity) do
    settings = entity.settings || %{}
    Map.get(settings, "public_form_success_message", gettext("Form submitted successfully!"))
  end

  defp apply_security_flags(metadata, [], _logger) do
    {metadata, "published"}
  end

  defp apply_security_flags(metadata, security_flags, logger) do
    # Build list of security warnings
    warnings =
      Enum.map(security_flags, fn {:triggered, type, action} ->
        %{"type" => Atom.to_string(type), "action" => action}
      end)

    # Check if any flag marks as suspicious
    is_suspicious =
      Enum.any?(security_flags, fn {:triggered, _type, action} ->
        action == "save_suspicious"
      end)

    # Check if any flag requires logging
    should_log =
      Enum.any?(security_flags, fn {:triggered, _type, action} ->
        action == "save_log"
      end)

    # Log warnings if needed
    if should_log do
      flag_types = Enum.map(security_flags, fn {:triggered, type, _} -> type end)
      logger.warning("Form submission with security flags: #{inspect(flag_types)}")
    end

    # Add warnings to metadata
    metadata = Map.put(metadata, "security_warnings", warnings)

    # Set status based on flags
    status = if is_suspicious, do: "draft", else: "published"

    {metadata, status}
  end

  defp handle_submission(conn, entity, params, security_flags) do
    require Logger

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

    # Capture submission metadata if enabled (default is true)
    collect_metadata = Map.get(settings, "public_form_collect_metadata") != false

    metadata =
      if collect_metadata,
        do: build_submission_metadata(conn, params),
        else: %{"source" => "public_form"}

    # Add security flags to metadata if any were triggered
    {metadata, status} = apply_security_flags(metadata, security_flags, Logger)

    entity_data_params = %{
      "entity_id" => entity.id,
      "title" => title,
      "slug" => generate_slug(title),
      "status" => status,
      "data" => filtered_data,
      "metadata" => metadata,
      "created_by" => created_by
    }

    case EntityData.create(entity_data_params) do
      {:ok, _data_record} ->
        # Track successful submission
        increment_form_stats(entity, :submitted, security_flags)

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
    enabled = Map.get(settings, "public_form_enabled", false)
    fields = Map.get(settings, "public_form_fields", [])
    # Form is only truly enabled if it's enabled AND has at least one field selected
    enabled && not Enum.empty?(fields)
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

  defp build_submission_metadata(conn, params) do
    user_agent = get_req_header(conn, "user-agent") |> List.first() || ""
    referer = get_req_header(conn, "referer") |> List.first()
    submitted_at = DateTime.utc_now()

    # Get form timing data
    form_loaded_at = Map.get(params, "_form_loaded_at")
    time_to_submit = get_time_to_submit(params)

    %{
      "source" => "public_form",
      "ip_address" => get_client_ip(conn),
      "user_agent" => user_agent,
      "browser" => parse_browser(user_agent),
      "os" => parse_os(user_agent),
      "device" => parse_device(user_agent),
      "referer" => referer,
      "form_loaded_at" => form_loaded_at,
      "submitted_at" => DateTime.to_iso8601(submitted_at),
      "time_to_submit_seconds" => time_to_submit
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

  # Form statistics tracking
  # Stats are stored in entity.settings under "public_form_stats"
  defp increment_form_stats(entity, event_type, security_flags) do
    # Run async to not block the response
    Task.start(fn ->
      try do
        current_settings = entity.settings || %{}
        current_stats = Map.get(current_settings, "public_form_stats", %{})

        # Initialize stats structure if needed
        updated_stats =
          current_stats
          |> Map.update("total_submissions", 1, &(&1 + 1))
          |> update_event_count(event_type)
          |> update_security_stats(security_flags)
          |> Map.put("last_submission_at", DateTime.utc_now() |> DateTime.to_iso8601())

        updated_settings = Map.put(current_settings, "public_form_stats", updated_stats)

        # Update entity settings directly via Repo
        Entities.update_entity(entity, %{"settings" => updated_settings})
      rescue
        _ -> :ok
      end
    end)
  end

  defp update_event_count(stats, :submitted) do
    Map.update(stats, "successful_submissions", 1, &(&1 + 1))
  end

  defp update_event_count(stats, :rejected) do
    Map.update(stats, "rejected_submissions", 1, &(&1 + 1))
  end

  defp update_security_stats(stats, []), do: stats

  defp update_security_stats(stats, security_flags) do
    Enum.reduce(security_flags, stats, fn {:triggered, type, _action}, acc ->
      key = "#{type}_triggers"
      Map.update(acc, key, 1, &(&1 + 1))
    end)
  end
end
