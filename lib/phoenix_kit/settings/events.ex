defmodule PhoenixKit.Settings.Events do
  @moduledoc """
  PubSub helpers for broadcasting settings updates in real-time.

  Allows multiple admins viewing Settings to see changes immediately
  without page refresh, similar to how Entities work.
  """

  alias PhoenixKit.PubSub.Manager

  @topic_settings "phoenix_kit:settings"

  @doc "Subscribe to settings change events."
  def subscribe_to_settings, do: Manager.subscribe(@topic_settings)

  @doc "Broadcast that content language setting was changed."
  def broadcast_content_language_changed(new_language) do
    Manager.broadcast(@topic_settings, {:content_language_changed, new_language})
  end

  @doc "Broadcast that admin languages were changed."
  def broadcast_admin_languages_changed(admin_languages) do
    Manager.broadcast(@topic_settings, {:admin_languages_changed, admin_languages})
  end

  @doc "Broadcast that any setting was changed (generic)."
  def broadcast_setting_changed(key, value) do
    Manager.broadcast(@topic_settings, {:setting_changed, key, value})
  end
end
