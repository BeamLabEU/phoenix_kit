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
             create_configuration_set: 2, create_configuration_set_event_destination: 5}

  # What happened to a message on its way: published for every setup.
  @delivery_event_types ~w(SEND REJECT BOUNCE COMPLAINT DELIVERY RENDERING_FAILURE DELIVERY_DELAY SUBSCRIPTION)

  # What the recipient did with it. Subscribing to these makes SES add a
  # tracking pixel to every message and rewrite every link through its own
  # redirect host, so they are published only when asked for.
  @engagement_event_types ~w(OPEN CLICK)

  @doc """
  The SES event types an event destination is created with.

  The eight delivery events always; `OPEN` and `CLICK` only when
  `track_opens_and_clicks?` is true.
  """
  @spec event_types(boolean()) :: [String.t()]
  def event_types(track_opens_and_clicks? \\ false)
  def event_types(true), do: @delivery_event_types ++ @engagement_event_types
  def event_types(_), do: @delivery_event_types

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
        case JSON.decode(body) do
          {:ok, %{"__type" => "AlreadyExistsException"}} ->
            {:ok, name}

          {:ok, %{"message" => msg}} ->
            # Check if it's an "already exists" message (AWS may return this without AlreadyExistsException type)
            if String.contains?(msg, "already exists") do
              {:ok, name}
            else
              {:error, msg}
            end

          _ ->
            {:error, body}
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc """
  Creates the event destination of a configuration set, or brings an existing
  one in line.

  Event destinations define where SES publishes email sending events (send,
  delivery, bounce, etc.).

  ## Parameters

    - `config_set_name` - Name of the configuration set
    - `destination_name` - Name for the event destination (e.g., "email-events-to-sns")
    - `topic_arn` - SNS topic ARN where events will be published
    - `config` - AWS configuration keyword list
    - `opts` - see Options

  ## Options

    - `:track_opens_and_clicks` - whether `OPEN` and `CLICK` are published.
      With them on, SES adds a tracking pixel to every message and rewrites
      every link in it through its own redirect host, the links of sign-in,
      confirmation and password-reset mail included.

      Left out, a new destination is created without the two and **an
      existing one is left exactly as it is**. Given as `true` or `false`, the
      caller has made a choice, so an existing destination is updated to it
      (`ses:UpdateConfigurationSetEventDestination`).

  ## Events Tracked

  `event_types/1` is the list. Always: `SEND`, `REJECT`, `BOUNCE`,
  `COMPLAINT`, `DELIVERY`, `RENDERING_FAILURE`, `DELIVERY_DELAY` and
  `SUBSCRIPTION`.

  ## Returns

    - `:ok` - the destination exists as asked
    - `{:error, reason}` - Failed to create or update it

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
        config,
        opts \\ []
      ) do
    choice = Keyword.get(opts, :track_opens_and_clicks)
    destination = event_destination(topic_arn, choice == true)
    base = "/v2/email/configuration-sets/#{URI.encode(config_set_name)}/event-destinations"

    create = %ExAws.Operation.JSON{
      http_method: :post,
      service: :ses,
      path: base,
      data: %{"EventDestinationName" => destination_name, "EventDestination" => destination},
      headers: [{"content-type", "application/json"}]
    }

    case destination_result(ExAws.request(create, config)) do
      :exists when is_boolean(choice) ->
        update = %ExAws.Operation.JSON{
          http_method: :put,
          service: :ses,
          path: base <> "/" <> URI.encode(destination_name),
          data: %{"EventDestination" => destination},
          headers: [{"content-type", "application/json"}]
        }

        case destination_result(ExAws.request(update, config)) do
          :exists -> :ok
          result -> result
        end

      :exists ->
        :ok

      result ->
        result
    end
  end

  defp event_destination(topic_arn, track?) do
    %{
      "Enabled" => true,
      "MatchingEventTypes" => event_types(track?),
      "SnsDestination" => %{"TopicArn" => topic_arn}
    }
  end

  # `:ok`, `:exists` (the create found one already there) or `{:error, reason}`.
  defp destination_result({:ok, _}), do: :ok
  defp destination_result({:error, {:http_error, 409, _}}), do: :exists

  defp destination_result({:error, {:http_error, _code, %{body: body}}}) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{"__type" => "AlreadyExistsException"}} ->
        :exists

      {:ok, %{"message" => msg}} ->
        if String.contains?(msg, "already exists"), do: :exists, else: {:error, msg}

      _ ->
        {:error, body}
    end
  end

  defp destination_result({:error, reason}), do: {:error, inspect(reason)}
end
