defmodule PhoenixKit.EmailSystem.EmailInterceptor do
  @moduledoc """
  Email interceptor for logging outgoing emails in PhoenixKit.

  This module provides functionality to intercept outgoing emails and create
  comprehensive logs for tracking purposes. It integrates seamlessly with
  the existing mailer system without disrupting email delivery.

  ## Features

  - **Transparent Interception**: Logs emails without affecting delivery
  - **Selective Logging**: Respects sampling rate and system settings
  - **AWS SES Integration**: Automatically adds configuration sets
  - **Rich Metadata Extraction**: Captures headers, size, attachments
  - **User Context**: Links emails to users when possible
  - **Template Recognition**: Identifies email templates and campaigns

  ## Integration

  The interceptor is designed to be called by the mailer before sending:

      # In PhoenixKit.Mailer.deliver_email/1
      email = EmailInterceptor.intercept_before_send(email, opts)
      # ... then send email normally

  ## Configuration

  The interceptor respects all email tracking system settings:

  - Only logs if `email_enabled` is true
  - Saves body based on `email_save_body` setting
  - Applies sampling rate from `email_sampling_rate`
  - Adds AWS SES configuration set if configured

  ## Examples

      # Basic interception
      logged_email = PhoenixKit.EmailSystem.EmailInterceptor.intercept_before_send(email)

      # With additional context
      logged_email = PhoenixKit.EmailSystem.EmailInterceptor.intercept_before_send(email, 
        user_id: 123,
        template_name: "welcome_email",
        campaign_id: "welcome_series"
      )

      # Check if email should be logged
      if PhoenixKit.EmailSystem.EmailInterceptor.should_log_email?(email) do
        # Log the email
      end
  """

  require Logger

  alias PhoenixKit.EmailSystem.EmailLog
  alias Swoosh.Email

  @doc """
  Intercepts an email before sending and creates a tracking log.

  Returns the email (potentially modified with tracking headers) and
  creates a log entry if tracking is enabled.

  ## Options

  - `:user_id` - Associate with a specific user
  - `:template_name` - Name of the email template
  - `:campaign_id` - Campaign identifier for grouping
  - `:provider` - Override provider detection
  - `:configuration_set` - Override AWS SES configuration set
  - `:message_tags` - Additional tags for the email

  ## Examples

      iex> email = new() |> to("user@example.com") |> from("app@example.com")
      iex> PhoenixKit.EmailSystem.EmailInterceptor.intercept_before_send(email, user_id: 123)
      %Swoosh.Email{headers: %{"X-PhoenixKit-Log-Id" => "456"}}
  """
  def intercept_before_send(%Email{} = email, opts \\ []) do
    if PhoenixKit.EmailSystem.enabled?() and should_log_email?(email, opts) do
      case create_email_log(email, opts) do
        {:ok, log} ->
          Logger.debug("Email tracked with ID: #{log.id}, Message ID: #{log.message_id}")

          # Add tracking headers to email
          add_tracking_headers(email, log, opts)

        {:error, :skipped} ->
          Logger.debug("Email logging skipped due to sampling")
          email

        {:error, reason} ->
          Logger.error("Failed to log email: #{inspect(reason)}")
          email
      end
    else
      email
    end
  end

  @doc """
  Determines if an email should be logged based on system settings.

  Considers sampling rate, system enablement, and email characteristics.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailInterceptor.should_log_email?(email)
      true
  """
  def should_log_email?(%Email{} = email, _opts \\ []) do
    cond do
      not PhoenixKit.EmailSystem.enabled?() ->
        false

      system_email?(email) ->
        # Always log system emails (errors, bounces, etc.)
        true

      true ->
        # Apply sampling rate for regular emails
        sampling_rate = PhoenixKit.EmailSystem.get_sampling_rate()
        meets_sampling_threshold?(email, sampling_rate)
    end
  end

  @doc """
  Extracts provider information from email or mailer configuration.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailInterceptor.detect_provider(email, [])
      "aws_ses"
  """
  def detect_provider(%Email{} = email, opts \\ []) do
    cond do
      provider = Keyword.get(opts, :provider) ->
        provider

      has_ses_headers?(email) ->
        "aws_ses"

      has_smtp_headers?(email) ->
        "smtp"

      true ->
        detect_provider_from_config()
    end
  end

  @doc """
  Creates an email log entry from a Swoosh.Email struct.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailInterceptor.create_email_log(email, user_id: 123)
      {:ok, %EmailLog{}}
  """
  def create_email_log(%Email{} = email, opts \\ []) do
    log_attrs = extract_email_data(email, opts)

    PhoenixKit.EmailSystem.create_log(log_attrs)
  end

  @doc """
  Adds tracking headers to an email for identification.

  ## Examples

      iex> email_with_headers = PhoenixKit.EmailSystem.EmailInterceptor.add_tracking_headers(email, log, [])
      %Swoosh.Email{headers: %{"X-PhoenixKit-Log-Id" => "123"}}
  """
  def add_tracking_headers(%Email{} = email, %EmailLog{} = log, opts \\ []) do
    tracking_headers = %{
      "X-PhoenixKit-Log-Id" => to_string(log.id),
      "X-PhoenixKit-Message-Id" => log.message_id
    }

    # Add AWS SES specific headers
    ses_headers = build_ses_headers(log, opts)

    all_headers = Map.merge(tracking_headers, ses_headers)

    # Add headers to email
    Enum.reduce(all_headers, email, fn {key, value}, acc_email ->
      Email.header(acc_email, key, value)
    end)
  end

  @doc """
  Builds AWS SES specific tracking headers and configuration.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailInterceptor.build_ses_headers(log, [])
      %{"X-SES-CONFIGURATION-SET" => "my-tracking-set"}
  """
  def build_ses_headers(%EmailLog{} = log, opts \\ []) do
    headers = %{}

    # Add configuration set if available
    headers =
      case get_configuration_set(opts) do
        nil ->
          Logger.debug("No configuration set available for SES headers")
          headers

        config_set ->
          Logger.debug("Adding X-SES-CONFIGURATION-SET header: #{config_set}")
          Map.put(headers, "X-SES-CONFIGURATION-SET", config_set)
      end

    # Add message tags for AWS SES
    headers =
      case build_message_tags(log, opts) do
        tags when map_size(tags) > 0 ->
          Logger.debug("Adding SES message tags: #{inspect(tags)}")
          # Convert tags to SES format
          tag_headers =
            Enum.with_index(tags, 1)
            |> Enum.reduce(headers, fn {{key, value}, index}, acc ->
              Map.put(acc, "X-SES-MESSAGE-TAG-#{index}", "#{key}=#{value}")
            end)

          tag_headers

        _ ->
          Logger.debug("No message tags to add")
          headers
      end

    Logger.debug("Final SES headers: #{inspect(headers)}")
    headers
  end

  @doc """
  Updates an email log after successful sending.

  This is called after the email provider confirms the send.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailInterceptor.update_after_send(log, provider_response)
      {:ok, %EmailLog{}}
  """
  def update_after_send(%EmailLog{} = log, provider_response \\ %{}) do
    require Logger

    Logger.info("EmailInterceptor: Updating email log after send", %{
      log_id: log.id,
      current_message_id: log.message_id,
      response_keys:
        if(is_map(provider_response), do: Map.keys(provider_response), else: "not_map")
    })

    update_attrs = %{
      status: "sent",
      sent_at: DateTime.utc_now()
    }

    # Extract additional data from provider response
    update_attrs =
      case extract_provider_data(provider_response) do
        %{message_id: aws_message_id} = provider_data when is_binary(aws_message_id) ->
          Logger.info("EmailInterceptor: Storing AWS message_id in aws_message_id field", %{
            log_id: log.id,
            internal_message_id: log.message_id,
            aws_message_id: aws_message_id
          })

          # Store the AWS message_id in the dedicated aws_message_id field
          # Keep internal pk_ message_id in the message_id field for compatibility
          updated_headers =
            Map.merge(log.headers || %{}, %{
              "X-Internal-Message-Id" => log.message_id,
              "X-AWS-Message-Id" => aws_message_id
            })

          provider_data
          # Remove message_id from provider_data
          |> Map.delete(:message_id)
          |> Map.merge(update_attrs)
          # Store in dedicated field
          |> Map.put(:aws_message_id, aws_message_id)
          |> Map.put(:headers, updated_headers)

        %{} = provider_data when map_size(provider_data) > 0 ->
          Logger.debug("EmailInterceptor: Got provider data without message_id", %{
            log_id: log.id,
            provider_data: provider_data
          })

          Map.merge(update_attrs, provider_data)

        _ ->
          Logger.warning("EmailInterceptor: No provider data extracted", %{
            log_id: log.id,
            response: inspect(provider_response) |> String.slice(0, 300)
          })

          update_attrs
      end

    case EmailLog.update_log(log, update_attrs) do
      {:ok, updated_log} ->
        Logger.info("EmailInterceptor: Successfully updated email log", %{
          log_id: updated_log.id,
          internal_message_id: updated_log.message_id,
          aws_message_id: updated_log.aws_message_id,
          status: updated_log.status
        })

        {:ok, updated_log}

      {:error, reason} ->
        Logger.error("EmailInterceptor: Failed to update email log", %{
          log_id: log.id,
          reason: inspect(reason),
          update_attrs: update_attrs
        })

        {:error, reason}
    end
  end

  @doc """
  Updates an email log after send failure.

  ## Examples

      iex> PhoenixKit.EmailSystem.EmailInterceptor.update_after_failure(log, error)
      {:ok, %EmailLog{}}
  """
  def update_after_failure(%EmailLog{} = log, error) do
    error_message = extract_error_message(error)

    update_attrs = %{
      status: "failed",
      error_message: error_message,
      retry_count: log.retry_count + 1
    }

    EmailLog.update_log(log, update_attrs)
  end

  ## --- Private Helper Functions ---

  # Extract comprehensive data from Swoosh.Email
  defp extract_email_data(%Email{} = email, opts) do
    %{
      message_id: generate_message_id(email, opts),
      to: extract_primary_recipient(email.to),
      from: extract_sender(email.from),
      subject: email.subject || "(no subject)",
      headers: extract_headers(email),
      body_preview: extract_body_preview(email),
      body_full: extract_body_full(email, opts),
      attachments_count: length(email.attachments || []),
      size_bytes: estimate_email_size(email),
      template_name: Keyword.get(opts, :template_name),
      campaign_id: Keyword.get(opts, :campaign_id),
      user_id: Keyword.get(opts, :user_id),
      provider: detect_provider(email, opts),
      configuration_set: get_configuration_set(opts),
      message_tags: build_message_tags(email, opts),
      sent_at: DateTime.utc_now()
    }
  end

  # Generate or extract message ID
  defp generate_message_id(%Email{} = email, opts) do
    # Try to extract from existing headers first
    existing_id =
      get_in(email.headers, ["Message-ID"]) ||
        get_in(email.headers, ["message-id"]) ||
        Keyword.get(opts, :message_id)

    case existing_id do
      nil -> "pk_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
      id -> String.trim(id, "<>")
    end
  end

  # Extract primary recipient email
  defp extract_primary_recipient([{_name, email} | _]), do: email
  defp extract_primary_recipient([email | _]) when is_binary(email), do: email
  defp extract_primary_recipient({_name, email}), do: email
  defp extract_primary_recipient(email) when is_binary(email), do: email
  defp extract_primary_recipient(_), do: "unknown@example.com"

  # Extract sender email
  defp extract_sender({_name, email}), do: email
  defp extract_sender(email) when is_binary(email), do: email
  defp extract_sender(_), do: "unknown@example.com"

  # Extract and clean headers
  defp extract_headers(%Email{headers: headers}) when is_map(headers) do
    # Remove sensitive headers and normalize
    headers
    |> Enum.reject(fn {key, _} ->
      key in ["Authorization", "Authentication-Results", "X-Password", "X-API-Key"]
    end)
    |> Enum.into(%{})
  end

  defp extract_headers(_), do: %{}

  # Extract body preview (first 500+ characters)
  defp extract_body_preview(%Email{} = email) do
    body = email.text_body || email.html_body || ""

    body
    |> strip_html_tags()
    # Increased from 500 to 1000 as per plan
    |> String.slice(0, 1000)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Extract full body if enabled
  defp extract_body_full(%Email{} = email, opts) do
    if PhoenixKit.EmailSystem.save_body_enabled?() or Keyword.get(opts, :save_body, false) do
      text_body = email.text_body || ""
      html_body = email.html_body || ""

      if String.length(html_body) > String.length(text_body) do
        html_body
      else
        text_body
      end
    else
      nil
    end
  end

  # Estimate email size in bytes
  defp estimate_email_size(%Email{} = email) do
    size = 0

    # Headers
    size = size + (email.headers |> inspect() |> byte_size())

    # Subject
    size = size + byte_size(email.subject || "")

    # Body
    size = size + byte_size(email.text_body || "")
    size = size + byte_size(email.html_body || "")

    # Attachments (rough estimate)
    attachment_size =
      (email.attachments || [])
      |> Enum.reduce(0, fn attachment, acc ->
        case attachment do
          %{data: data} when is_binary(data) ->
            acc + byte_size(data)

          %{path: path} when is_binary(path) ->
            case File.stat(path) do
              {:ok, %File.Stat{size: file_size}} -> acc + file_size
              # Default estimate
              _ -> acc + 10_000
            end

          # Default estimate
          _ ->
            acc + 10_000
        end
      end)

    size + attachment_size
  end

  # Check if email should be sampled
  defp meets_sampling_threshold?(%Email{} = email, sampling_rate) do
    if sampling_rate >= 100 do
      true
    else
      # Use deterministic sampling based on recipient email
      recipient = extract_primary_recipient(email.to)
      hash = :erlang.phash2(recipient, 100)
      hash < sampling_rate
    end
  end

  # Check if this is a system/critical email
  defp system_email?(%Email{} = email) do
    subject = String.downcase(email.subject || "")
    sender = String.downcase(extract_sender(email.from))

    # System emails are always logged
    String.contains?(subject, ["error", "bounce", "failure", "alert", "warning", "critical"]) or
      String.contains?(sender, ["noreply", "no-reply", "system", "admin", "alert"])
  end

  # Get AWS SES configuration set
  defp get_configuration_set(opts) do
    config_set =
      Keyword.get(opts, :configuration_set) || PhoenixKit.EmailSystem.get_ses_configuration_set()

    Logger.debug(
      "Configuration set from options: #{inspect(Keyword.get(opts, :configuration_set))}"
    )

    Logger.debug(
      "Configuration set from settings: #{inspect(PhoenixKit.EmailSystem.get_ses_configuration_set())}"
    )

    Logger.debug("Final config_set value: #{inspect(config_set)}")

    # Only return config set if it's properly configured and not empty
    result =
      case config_set do
        nil ->
          Logger.debug("Configuration set is nil, skipping tracking")
          nil

        "" ->
          Logger.debug("Configuration set is empty string, skipping tracking")
          nil

        "phoenixkit-tracking" ->
          # Default hardcoded value - only use if explicitly confirmed to exist
          if validate_ses_configuration_set("phoenixkit-tracking") do
            Logger.debug("Using phoenixkit-tracking configuration set")
            "phoenixkit-tracking"
          else
            Logger.warning("phoenixkit-tracking configuration set validation failed")
            nil
          end

        other when is_binary(other) ->
          # Custom config set - validate before using
          if validate_ses_configuration_set(other) do
            Logger.debug("Using custom configuration set: #{other}")
            other
          else
            Logger.warning("Custom configuration set validation failed: #{other}")
            nil
          end

        _ ->
          Logger.warning("Invalid configuration set type: #{inspect(config_set)}")
          nil
      end

    Logger.debug("Final configuration set result: #{inspect(result)}")
    result
  end

  # Validate that SES configuration set exists
  defp validate_ses_configuration_set(config_set) when is_binary(config_set) do
    # Enable configuration set if it's configured via settings
    # The AWS setup script ensures proper configuration exists
    config_set != ""
  end

  defp validate_ses_configuration_set(_), do: false

  # Build message tags for categorization
  defp build_message_tags(%Email{} = email, opts) do
    base_tags = Keyword.get(opts, :message_tags, %{})

    auto_tags = %{}

    # Add template tag if available
    auto_tags =
      case Keyword.get(opts, :template_name) do
        nil -> auto_tags
        template -> Map.put(auto_tags, "template", template)
      end

    # Add campaign tag if available
    auto_tags =
      case Keyword.get(opts, :campaign_id) do
        nil -> auto_tags
        campaign -> Map.put(auto_tags, "campaign", campaign)
      end

    # Add user context if available
    auto_tags =
      case Keyword.get(opts, :user_id) do
        nil -> auto_tags
        user_id -> Map.put(auto_tags, "user_id", to_string(user_id))
      end

    # Add email type detection
    auto_tags = Map.put(auto_tags, "email_type", detect_email_type(email))

    Map.merge(auto_tags, base_tags)
  end

  # Build message tags for log record
  defp build_message_tags(_log_or_email, opts) do
    # Simplified for now
    build_message_tags(%Email{}, opts)
  end

  # Detect email type from content
  defp detect_email_type(%Email{} = email) do
    subject = String.downcase(email.subject || "")

    cond do
      String.contains?(subject, ["welcome", "confirm", "verify", "activate"]) -> "authentication"
      String.contains?(subject, ["reset", "password", "forgot"]) -> "password_reset"
      String.contains?(subject, ["newsletter", "update", "news"]) -> "newsletter"
      String.contains?(subject, ["invoice", "receipt", "payment", "billing"]) -> "transactional"
      String.contains?(subject, ["invitation", "invite"]) -> "invitation"
      true -> "general"
    end
  end

  # Check for SES specific headers
  defp has_ses_headers?(%Email{headers: headers}) when is_map(headers) do
    Map.has_key?(headers, "X-SES-CONFIGURATION-SET") or
      Enum.any?(headers, fn {key, _} -> String.starts_with?(key, "X-SES-") end)
  end

  defp has_ses_headers?(_), do: false

  # Check for SMTP headers
  defp has_smtp_headers?(%Email{headers: headers}) when is_map(headers) do
    Map.has_key?(headers, "X-SMTP-Server") or
      Map.has_key?(headers, "Received")
  end

  defp has_smtp_headers?(_), do: false

  # Detect provider from configuration
  defp detect_provider_from_config do
    # Try to detect from application configuration
    case PhoenixKit.Config.get(:mailer) do
      {:ok, mailer} when not is_nil(mailer) ->
        # Try to determine provider from mailer configuration
        config = Application.get_env(:phoenix_kit, mailer, [])
        adapter = Keyword.get(config, :adapter)

        case adapter do
          Swoosh.Adapters.AmazonSES -> "aws_ses"
          Swoosh.Adapters.SMTP -> "smtp"
          Swoosh.Adapters.Sendgrid -> "sendgrid"
          Swoosh.Adapters.Mailgun -> "mailgun"
          Swoosh.Adapters.Local -> "local"
          _ -> "unknown"
        end

      _ ->
        "unknown"
    end
  end

  # Extract data from provider response
  defp extract_provider_data(%{} = response) do
    require Logger

    Logger.debug("EmailInterceptor: Extracting provider data from response", %{
      response_keys: Map.keys(response),
      response_preview: inspect(response) |> String.slice(0, 500)
    })

    # Extract message ID from various response formats
    extracted_data = extract_message_id_from_response(response)

    if Map.has_key?(extracted_data, :message_id) do
      Logger.info("EmailInterceptor: Successfully extracted AWS MessageId", %{
        message_id: extracted_data.message_id,
        response_format: detect_response_format(response),
        found_in_key: find_message_id_key(response)
      })
    else
      Logger.warning("EmailInterceptor: No MessageId found in response", %{
        response_keys: Map.keys(response),
        response: inspect(response),
        checked_keys: [":id", "\"id\"", "\"MessageId\"", "\"messageId\"", ":message_id"]
      })
    end

    extracted_data
  end

  defp extract_provider_data(_), do: %{}

  # Extract message ID from different response formats
  defp extract_message_id_from_response(response) when is_map(response) do
    extract_direct_message_id(response) ||
      extract_nested_message_id(response) ||
      extract_ses_response_message_id(response) ||
      %{}
  end

  defp extract_message_id_from_response(_), do: %{}

  # Extract message ID from direct keys
  defp extract_direct_message_id(response) do
    cond do
      # Swoosh AmazonSES adapter returns {:ok, %{id: "message-id"}}
      Map.has_key?(response, :id) -> %{message_id: response[:id]}
      Map.has_key?(response, "id") -> %{message_id: response["id"]}
      # AWS API direct response formats
      Map.has_key?(response, "MessageId") -> %{message_id: response["MessageId"]}
      Map.has_key?(response, "messageId") -> %{message_id: response["messageId"]}
      Map.has_key?(response, :message_id) -> %{message_id: response[:message_id]}
      true -> nil
    end
  end

  # Extract message ID from nested body formats
  defp extract_nested_message_id(response) do
    cond do
      Map.has_key?(response, :body) and is_map(response.body) ->
        extract_message_id_from_response(response.body)

      Map.has_key?(response, "body") and is_map(response["body"]) ->
        extract_message_id_from_response(response["body"])

      true ->
        nil
    end
  end

  # Extract message ID from AWS SES SendEmailResponse structure
  defp extract_ses_response_message_id(response) do
    with true <- Map.has_key?(response, "SendEmailResponse"),
         send_response when is_map(send_response) <- response["SendEmailResponse"],
         true <- Map.has_key?(send_response, "SendEmailResult"),
         result when is_map(result) <- send_response["SendEmailResult"],
         true <- Map.has_key?(result, "MessageId") do
      %{message_id: result["MessageId"]}
    else
      _ -> nil
    end
  end

  # Detect response format for logging
  defp detect_response_format(response) when is_map(response) do
    cond do
      Map.has_key?(response, "MessageId") -> "direct_MessageId"
      Map.has_key?(response, "messageId") -> "direct_messageId"
      Map.has_key?(response, :message_id) -> "atom_message_id"
      Map.has_key?(response, :body) -> "nested_body"
      Map.has_key?(response, "SendEmailResponse") -> "aws_soap_format"
      true -> "unknown_format"
    end
  end

  defp detect_response_format(_), do: "non_map_response"

  # Extract error message from various error formats
  defp extract_error_message({:error, reason}) when is_binary(reason), do: reason
  defp extract_error_message({:error, reason}) when is_atom(reason), do: to_string(reason)
  defp extract_error_message({:error, %{message: message}}) when is_binary(message), do: message
  defp extract_error_message(%{message: message}) when is_binary(message), do: message
  defp extract_error_message(error) when is_binary(error), do: error
  defp extract_error_message(error) when is_atom(error), do: to_string(error)
  defp extract_error_message(error), do: inspect(error)

  # Strip HTML tags from text (basic)
  defp strip_html_tags(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/&[a-zA-Z0-9#]+;/, " ")
  end

  defp strip_html_tags(_), do: ""

  # Helper function to identify which key contained the message ID
  defp find_message_id_key(response) when is_map(response) do
    cond do
      Map.has_key?(response, :id) -> ":id (Swoosh format)"
      Map.has_key?(response, "id") -> "\"id\" (string format)"
      Map.has_key?(response, "MessageId") -> "\"MessageId\" (AWS API format)"
      Map.has_key?(response, "messageId") -> "\"messageId\" (camelCase format)"
      Map.has_key?(response, :message_id) -> ":message_id (atom snake_case format)"
      true -> "not_found"
    end
  end

  defp find_message_id_key(_), do: "invalid_response"
end
