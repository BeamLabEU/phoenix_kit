defmodule PhoenixKitWeb.Live.Modules.EmailSystemLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.EmailSystem
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(_params, session, socket) do
    # Get current path for navigation
    current_path = get_current_path(socket, session)

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load email configuration
    email_config = EmailSystem.get_config()

    # Load AWS settings
    aws_settings = %{
      access_key_id: Settings.get_setting("aws_access_key_id", ""),
      secret_access_key: Settings.get_setting("aws_secret_access_key", ""),
      region: Settings.get_setting("aws_region", "eu-north-1"),
      sqs_queue_url: Settings.get_setting("aws_sqs_queue_url", ""),
      sqs_dlq_url: Settings.get_setting("aws_sqs_dlq_url", ""),
      sqs_queue_arn: Settings.get_setting("aws_sqs_queue_arn", ""),
      sns_topic_arn: Settings.get_setting("aws_sns_topic_arn", ""),
      ses_configuration_set:
        Settings.get_setting("aws_ses_configuration_set", "phoenixkit-tracking"),
      sqs_polling_interval_ms: Settings.get_setting("sqs_polling_interval_ms", "5000")
    }

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:page_title, "Emails")
      |> assign(:project_title, project_title)
      |> assign(:email_enabled, email_config.enabled)
      |> assign(:email_save_body, email_config.save_body)
      |> assign(:email_ses_events, email_config.ses_events)
      |> assign(:email_retention_days, email_config.retention_days)
      |> assign(:email_sampling_rate, email_config.sampling_rate)
      |> assign(:email_compress_body, email_config.compress_after_days)
      |> assign(:email_archive_to_s3, email_config.archive_to_s3)
      |> assign(:email_cloudwatch_metrics, email_config.cloudwatch_metrics)
      |> assign(:sqs_polling_enabled, email_config.sqs_polling_enabled)
      |> assign(:sqs_polling_interval_ms, email_config.sqs_polling_interval_ms)
      |> assign(:aws_settings, aws_settings)
      |> assign(:saving, false)

    {:ok, socket}
  end

  def handle_event("toggle_emails", _params, socket) do
    # Toggle email system
    new_enabled = !socket.assigns.email_enabled

    result =
      if new_enabled do
        EmailSystem.enable_system()
      else
        EmailSystem.disable_system()
      end

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_enabled, new_enabled)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Email system enabled",
              else: "Email system disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update email system")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_email_save_body", _params, socket) do
    # Toggle email body saving
    new_save_body = !socket.assigns.email_save_body

    result = EmailSystem.set_save_body(new_save_body)

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_save_body, new_save_body)
          |> put_flash(
            :info,
            if(new_save_body,
              do: "Email body saving enabled",
              else: "Email body saving disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update email body saving setting")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_email_ses_events", _params, socket) do
    # Toggle AWS SES events tracking
    new_ses_events = !socket.assigns.email_ses_events

    result = EmailSystem.set_ses_events(new_ses_events)

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_ses_events, new_ses_events)
          |> put_flash(
            :info,
            if(new_ses_events,
              do: "AWS SES events tracking enabled",
              else: "AWS SES events tracking disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update AWS SES events tracking")
        {:noreply, socket}
    end
  end

  def handle_event("update_email_sampling_rate", %{"sampling_rate" => value}, socket) do
    case Integer.parse(value) do
      {sampling_rate, _} when sampling_rate >= 0 and sampling_rate <= 100 ->
        case EmailSystem.set_sampling_rate(sampling_rate) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:email_sampling_rate, sampling_rate)
              |> put_flash(:info, "Email sampling rate updated to #{sampling_rate}%")

            {:noreply, socket}

          {:error, _changeset} ->
            socket = put_flash(socket, :error, "Failed to update email sampling rate")
            {:noreply, socket}
        end

      _ ->
        socket = put_flash(socket, :error, "Please enter a valid number between 0 and 100")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_sqs_polling", _params, socket) do
    # Toggle SQS polling
    new_sqs_polling = !socket.assigns.sqs_polling_enabled

    result = EmailSystem.set_sqs_polling(new_sqs_polling)

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:sqs_polling_enabled, new_sqs_polling)
          |> put_flash(
            :info,
            if(new_sqs_polling,
              do: "SQS polling enabled",
              else: "SQS polling disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update SQS polling setting")
        {:noreply, socket}
    end
  end

  def handle_event("update_email_retention", %{"retention_days" => value}, socket) do
    case Integer.parse(value) do
      {retention_days, _} when retention_days > 0 and retention_days <= 365 ->
        case EmailSystem.set_retention_days(retention_days) do
          {:ok, _setting} ->
            socket =
              socket
              |> assign(:email_retention_days, retention_days)
              |> put_flash(:info, "Email retention period updated to #{retention_days} days")

            {:noreply, socket}

          {:error, _changeset} ->
            socket = put_flash(socket, :error, "Failed to update email retention period")
            {:noreply, socket}
        end

      _ ->
        socket = put_flash(socket, :error, "Please enter a valid number between 1 and 365")
        {:noreply, socket}
    end
  end

  def handle_event("save_aws_settings", %{"aws_settings" => aws_params}, socket) do
    socket = assign(socket, :saving, true)

    update_results = update_all_aws_settings(aws_params)

    case Enum.all?(update_results, &match?({:ok, _}, &1)) do
      true ->
        new_aws_settings = build_aws_settings_map(aws_params)

        socket =
          socket
          |> assign(:aws_settings, new_aws_settings)
          |> assign(:saving, false)
          |> put_flash(:info, "AWS settings saved successfully")

        {:noreply, socket}

      false ->
        socket =
          socket
          |> assign(:saving, false)
          |> put_flash(:error, "Failed to save AWS settings")

        {:noreply, socket}
    end
  end

  defp get_current_path(_socket, _session) do
    # For Email settings page
    Routes.path("/admin/settings/emails")
  end

  # Update all AWS settings in database
  defp update_all_aws_settings(aws_params) do
    [
      Settings.update_setting("aws_access_key_id", aws_params["access_key_id"] || ""),
      Settings.update_setting("aws_secret_access_key", aws_params["secret_access_key"] || ""),
      Settings.update_setting("aws_region", aws_params["region"] || "eu-north-1"),
      Settings.update_setting("aws_sqs_queue_url", aws_params["sqs_queue_url"] || ""),
      Settings.update_setting("aws_sqs_dlq_url", aws_params["sqs_dlq_url"] || ""),
      Settings.update_setting("aws_sqs_queue_arn", aws_params["sqs_queue_arn"] || ""),
      Settings.update_setting("aws_sns_topic_arn", aws_params["sns_topic_arn"] || ""),
      Settings.update_setting(
        "aws_ses_configuration_set",
        aws_params["ses_configuration_set"] || "phoenixkit-tracking"
      ),
      Settings.update_setting(
        "sqs_polling_interval_ms",
        aws_params["sqs_polling_interval_ms"] || "5000"
      )
    ]
  end

  # Build AWS settings map from params
  defp build_aws_settings_map(aws_params) do
    %{
      access_key_id: aws_params["access_key_id"] || "",
      secret_access_key: aws_params["secret_access_key"] || "",
      region: aws_params["region"] || "eu-north-1",
      sqs_queue_url: aws_params["sqs_queue_url"] || "",
      sqs_dlq_url: aws_params["sqs_dlq_url"] || "",
      sqs_queue_arn: aws_params["sqs_queue_arn"] || "",
      sns_topic_arn: aws_params["sns_topic_arn"] || "",
      ses_configuration_set: aws_params["ses_configuration_set"] || "phoenixkit-tracking",
      sqs_polling_interval_ms: aws_params["sqs_polling_interval_ms"] || "5000"
    }
  end
end
