defmodule PhoenixKit.Users.CustomFields.Events do
  @moduledoc """
  PubSub event broadcasting for custom field changes.

  Allows different parts of the application to react to custom field
  modifications in real-time.
  """

  alias PhoenixKit.PubSub.Manager

  @topic_custom_fields "custom_fields"

  @doc """
  Subscribe to custom field change events.
  """
  def subscribe do
    Manager.subscribe(@topic_custom_fields)
  end

  @doc """
  Broadcast that a custom field was deleted.
  """
  def broadcast_field_deleted(field_key) do
    Manager.broadcast(@topic_custom_fields, {:custom_field_deleted, field_key})
  end

  @doc """
  Broadcast that custom fields have changed (added, updated, reordered).
  """
  def broadcast_fields_changed do
    Manager.broadcast(@topic_custom_fields, :custom_fields_changed)
  end
end
