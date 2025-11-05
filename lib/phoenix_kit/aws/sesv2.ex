defmodule PhoenixKit.AWS.SESv2 do
  @moduledoc """
  AWS SES v2 API client for operations not supported by ExAws.

  This module provides direct API access to AWS SES v2 features that are not yet
  available in the ExAws library, enabling infrastructure setup without AWS CLI dependency.

  ## Features

  - Configuration set creation and management
  - Event destination configuration for email tracking
  - Automatic handling of "already exists" scenarios
  - Production-ready error messages

  ## Usage

      config = [
        access_key_id: "AKIA...",
        secret_access_key: "...",
        region: "eu-north-1"
      ]

      # Create configuration set
      {:ok, name} = SESv2.create_configuration_set("myapp-emailing", config)

      # Configure event tracking
      :ok = SESv2.create_configuration_set_event_destination(
        "myapp-emailing",
        "email-events-to-sns",
        "arn:aws:sns:eu-north-1:123456:topic",
        config
      )

  """

  require Logger

  @dialyzer {:nowarn_function,
             create_configuration_set: 2, create_configuration_set_event_destination: 4}

  @doc """
  Creates a SES configuration set.

  Configuration sets allow you to publish email sending events to Amazon SNS, CloudWatch, or Kinesis Firehose.

  ## Parameters

    - `name` - Name of the configuration set (string)
    - `config` - AWS configuration keyword list with:
      - `:access_key_id` - AWS access key ID
      - `:secret_access_key` - AWS secret access key
      - `:region` - AWS region (e.g., "eu-north-1")

  ## Returns

    - `{:ok, name}` - Configuration set created or already exists
    - `{:error, reason}` - Failed to create configuration set

  ## Examples

      iex> config = [access_key_id: "AKIA...", secret_access_key: "...", region: "eu-north-1"]
      iex> SESv2.create_configuration_set("myapp-emailing", config)
      {:ok, "myapp-emailing"}

      # If configuration set already exists, returns success
      iex> SESv2.create_configuration_set("myapp-emailing", config)
      {:ok, "myapp-emailing"}

  """
  def create_configuration_set(name, config) do
    # Use ExAws.Operation.JSON for SES v2 API
    # IMPORTANT: service must be :ses (not :email) for correct AWS signature
    request = %ExAws.Operation.JSON{
      http_method: :post,
      service: :ses,
      path: "/v2/email/configuration-sets",
      data: %{"ConfigurationSetName" => name},
      headers: [
        {"content-type", "application/json"}
      ]
    }

    case ExAws.request(request, config) do
      {:ok, _} ->
        {:ok, name}

      {:error, {:http_error, 409, _}} ->
        # Already exists - this is fine
        {:ok, name}

      {:error, {:http_error, _code, %{body: body}}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{"__type" => "AlreadyExistsException"}} ->
            {:ok, name}

          {:ok, %{"message" => msg}} ->
            {:error, msg}

          _ ->
            {:error, body}
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc """
  Creates an event destination for a configuration set.

  Event destinations define where SES publishes email sending events (send, delivery, bounce, etc.).

  ## Parameters

    - `config_set_name` - Name of the configuration set
    - `destination_name` - Name for the event destination (e.g., "email-events-to-sns")
    - `topic_arn` - SNS topic ARN where events will be published
    - `config` - AWS configuration keyword list

  ## Returns

    - `:ok` - Event destination created or already exists
    - `{:error, reason}` - Failed to create event destination

  ## Events Tracked

  The event destination is configured to track all email event types:
  - `SEND` - Email accepted by AWS SES
  - `REJECT` - Email rejected before sending
  - `BOUNCE` - Email bounced (hard or soft)
  - `COMPLAINT` - Recipient marked email as spam
  - `DELIVERY` - Email successfully delivered
  - `OPEN` - Recipient opened email (tracking pixel loaded)
  - `CLICK` - Recipient clicked link in email
  - `RENDERING_FAILURE` - Email template failed to render

  ## Examples

      iex> topic_arn = "arn:aws:sns:eu-north-1:123456:myapp-email-events"
      iex> SESv2.create_configuration_set_event_destination(
      ...>   "myapp-emailing",
      ...>   "email-events-to-sns",
      ...>   topic_arn,
      ...>   config
      ...> )
      :ok

  """
  def create_configuration_set_event_destination(
        config_set_name,
        destination_name,
        topic_arn,
        config
      ) do
    data = %{
      "EventDestinationName" => destination_name,
      "EventDestination" => %{
        "Enabled" => true,
        "MatchingEventTypes" => [
          "SEND",
          "REJECT",
          "BOUNCE",
          "COMPLAINT",
          "DELIVERY",
          "OPEN",
          "CLICK",
          "RENDERING_FAILURE",
          "DELIVERY_DELAY",
          "SUBSCRIPTION"
        ],
        "SnsDestination" => %{
          "TopicArn" => topic_arn
        }
      }
    }

    request = %ExAws.Operation.JSON{
      http_method: :post,
      service: :ses,
      path: "/v2/email/configuration-sets/#{URI.encode(config_set_name)}/event-destinations",
      data: data,
      headers: [
        {"content-type", "application/json"}
      ]
    }

    case ExAws.request(request, config) do
      {:ok, _} ->
        :ok

      {:error, {:http_error, 409, _}} ->
        # Already exists - this is fine
        :ok

      {:error, {:http_error, _code, %{body: body}}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{"__type" => "AlreadyExistsException"}} ->
            :ok

          {:ok, %{"message" => msg}} ->
            # Check if message indicates resource already exists
            if String.contains?(msg, "already exists"), do: :ok, else: {:error, msg}

          _ ->
            {:error, body}
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
