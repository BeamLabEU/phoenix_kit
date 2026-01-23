defmodule PhoenixKit.PubSubHelper do
  @moduledoc """
  Helper for dynamically resolving the PubSub server to use.

  This module provides functions to get the appropriate PubSub server
  based on configuration. It will use the configured pubsub from
  the parent application.

  ## Configuration

  Configure the PubSub server in your application:

      config :phoenix_kit, pubsub: MyApp.PubSub

  If not configured, PhoenixKit will attempt to derive it from the
  parent app name (e.g., MyApp -> MyApp.PubSub).
  """

  alias PhoenixKit.Config

  @doc """
  Gets the PubSub server module to use.

  Returns the configured pubsub server, or derives it from parent_module config.
  """
  def pubsub do
    case Config.get(:pubsub, nil) do
      nil ->
        # Try to derive from parent_module config
        case Config.get(:parent_module, nil) do
          nil ->
            # Last resort fallback - will fail at runtime if not configured
            PhoenixKit.PubSub

          parent_module ->
            Module.concat(parent_module, PubSub)
        end

      pubsub when is_atom(pubsub) ->
        pubsub
    end
  end

  @doc """
  Gets the PubSub server from socket endpoint config.

  This is useful in LiveView contexts where the socket has access to
  the endpoint configuration.
  """
  def pubsub_from_socket(socket) do
    socket.endpoint.config(:pubsub_server) || pubsub()
  end

  @doc """
  Subscribes to a topic using the configured PubSub server.
  """
  def subscribe(topic) do
    Phoenix.PubSub.subscribe(pubsub(), topic)
  end

  @doc """
  Subscribes to a topic using a specific PubSub server.
  """
  def subscribe(pubsub_server, topic) do
    Phoenix.PubSub.subscribe(pubsub_server, topic)
  end

  @doc """
  Broadcasts a message to a topic using the configured PubSub server.
  """
  def broadcast(topic, message) do
    Phoenix.PubSub.broadcast(pubsub(), topic, message)
  end

  @doc """
  Broadcasts a message using a specific PubSub server.
  """
  def broadcast(pubsub_server, topic, message) do
    Phoenix.PubSub.broadcast(pubsub_server, topic, message)
  end
end
