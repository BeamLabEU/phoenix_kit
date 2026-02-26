defmodule PhoenixKit.Modules.Entities.Events do
  @moduledoc """
  PubSub helpers for coordinating real-time entity updates.

  Provides broadcast and subscribe helpers for:

    * Entity definition lifecycle (create/update/delete)
    * Entity data lifecycle (create/update/delete)
    * Collaborative editing signals for entity + data forms

  All events are broadcast through `PhoenixKit.PubSub.Manager` so the library
  remains self-contained when embedded into host applications.
  """

  alias PhoenixKit.PubSub.Manager

  # Base topics
  @topic_entities "phoenix_kit:entities:definitions"
  @topic_data "phoenix_kit:entities:data"
  @topic_entity_forms "phoenix_kit:entities:entity_forms"
  @topic_data_forms "phoenix_kit:entities:data_forms"

  ## Subscription helpers

  @doc "Subscribe to entity definition lifecycle events."
  def subscribe_to_entities, do: Manager.subscribe(@topic_entities)

  @doc "Subscribe to entity data lifecycle events (all entities)."
  def subscribe_to_all_data, do: Manager.subscribe(@topic_data)

  @doc "Subscribe to data lifecycle events for a specific entity."
  def subscribe_to_entity_data(entity_id), do: Manager.subscribe(data_topic(entity_id))

  @doc "Subscribe to collaborative events for a specific entity form."
  def subscribe_to_entity_form(form_key),
    do: Manager.subscribe(entity_form_topic(form_key))

  @doc "Subscribe to collaborative events for a specific data record form."
  def subscribe_to_data_form(entity_id, record_key),
    do: Manager.subscribe(data_form_topic(entity_id, record_key))

  @doc "Subscribe to presence updates for an entity."
  def subscribe_to_entity_presence(entity_id),
    do: Manager.subscribe(entity_presence_topic(entity_id))

  @doc "Subscribe to presence updates for a data record."
  def subscribe_to_data_presence(entity_id, data_id),
    do: Manager.subscribe(data_presence_topic(entity_id, data_id))

  ## Entity definition lifecycle

  def broadcast_entity_created(entity_id),
    do: broadcast(@topic_entities, {:entity_created, entity_id})

  def broadcast_entity_updated(entity_id),
    do: broadcast(@topic_entities, {:entity_updated, entity_id})

  def broadcast_entity_deleted(entity_id),
    do: broadcast(@topic_entities, {:entity_deleted, entity_id})

  ## Entity data lifecycle

  def broadcast_data_created(entity_id, data_id) do
    message = {:data_created, entity_id, data_id}
    broadcast(@topic_data, message)
    broadcast(data_topic(entity_id), message)
  end

  def broadcast_data_updated(entity_id, data_id) do
    message = {:data_updated, entity_id, data_id}
    broadcast(@topic_data, message)
    broadcast(data_topic(entity_id), message)
  end

  def broadcast_data_deleted(entity_id, data_id) do
    message = {:data_deleted, entity_id, data_id}
    broadcast(@topic_data, message)
    broadcast(data_topic(entity_id), message)
  end

  ## Collaborative form editing

  def broadcast_entity_form_change(form_key, payload, opts \\ []) do
    broadcast(
      entity_form_topic(form_key),
      {:entity_form_change, form_key, payload, Keyword.get(opts, :source)}
    )
  end

  def broadcast_data_form_change(entity_id, record_key, payload, opts \\ []) do
    broadcast(
      data_form_topic(entity_id, record_key),
      {:data_form_change, entity_id, normalize_record_key(record_key), payload,
       Keyword.get(opts, :source)}
    )
  end

  ## State synchronization for new joiners

  def broadcast_entity_form_sync_request(form_key, requester_socket_id) do
    broadcast(
      entity_form_topic(form_key),
      {:entity_form_sync_request, form_key, requester_socket_id}
    )
  end

  def broadcast_entity_form_sync_response(form_key, requester_socket_id, state) do
    broadcast(
      entity_form_topic(form_key),
      {:entity_form_sync_response, form_key, requester_socket_id, state}
    )
  end

  def broadcast_data_form_sync_request(entity_id, record_key, requester_socket_id) do
    broadcast(
      data_form_topic(entity_id, record_key),
      {:data_form_sync_request, entity_id, normalize_record_key(record_key), requester_socket_id}
    )
  end

  def broadcast_data_form_sync_response(entity_id, record_key, requester_socket_id, state) do
    broadcast(
      data_form_topic(entity_id, record_key),
      {:data_form_sync_response, entity_id, normalize_record_key(record_key), requester_socket_id,
       state}
    )
  end

  ## Topic helpers

  defp data_topic(entity_id), do: "#{@topic_data}:#{entity_id}"

  defp entity_form_topic(form_key), do: "#{@topic_entity_forms}:#{form_key}"

  defp data_form_topic(entity_id, record_key),
    do: "#{@topic_data_forms}:#{entity_id}:#{normalize_record_key(record_key)}"

  defp entity_presence_topic(entity_id),
    do: "phoenix_kit:entities:presence:entity:#{entity_id}"

  defp data_presence_topic(entity_id, data_id),
    do: "phoenix_kit:entities:presence:data:#{entity_id}:#{data_id}"

  defp normalize_record_key({:new, slug}), do: "new-#{slug}"
  defp normalize_record_key(record_key) when is_atom(record_key), do: Atom.to_string(record_key)

  defp normalize_record_key(record_key), do: to_string(record_key)

  defp broadcast(topic, payload), do: Manager.broadcast(topic, payload)
end
