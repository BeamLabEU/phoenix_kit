defmodule PhoenixkitEu.AWS.SESv2 do
  @moduledoc """
  AWS SES v2 API client for operations not supported by ExAws.

  Uses ExAws.Operation.RestQuery to make signed requests to SES v2 API.
  """

  require Logger

  @doc """
  Creates a SES configuration set.

  ## Parameters
    - `name`: Name of the configuration set
    - `config`: AWS configuration (access_key_id, secret_access_key, region)

  ## Returns
    - `{:ok, name}` on success
    - `{:error, reason}` on failure
  """
  def create_configuration_set(name, config) do
    # Use ExAws.Operation.JSON for SES v2 API
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
        # Already exists
        {:ok, name}

      {:error, {:http_error, _code, %{body: body}}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{"__type" => "AlreadyExistsException"}} -> {:ok, name}
          {:ok, %{"message" => msg}} -> {:error, msg}
          _ -> {:error, body}
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc """
  Creates an event destination for a configuration set.

  ## Parameters
    - `config_set_name`: Name of the configuration set
    - `destination_name`: Name of the event destination
    - `topic_arn`: SNS topic ARN for events
    - `config`: AWS configuration

  ## Returns
    - `:ok` on success
    - `{:error, reason}` on failure
  """
  def create_configuration_set_event_destination(config_set_name, destination_name, topic_arn, config) do
    data = %{
      "EventDestinationName" => destination_name,
      "EventDestination" => %{
        "Enabled" => true,
        "MatchingEventTypes" => [
          "SEND", "REJECT", "BOUNCE", "COMPLAINT",
          "DELIVERY", "OPEN", "CLICK", "RENDERING_FAILURE"
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
        # Already exists
        :ok

      {:error, {:http_error, _code, %{body: body}}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{"__type" => "AlreadyExistsException"}} -> :ok
          {:ok, %{"message" => msg}} ->
            if String.contains?(msg, "already exists"), do: :ok, else: {:error, msg}
          _ -> {:error, body}
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
