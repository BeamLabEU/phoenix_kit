defmodule PhoenixKit.Modules.Publishing.Constants do
  @moduledoc """
  Centralized constants for the Publishing module.

  Provides canonical lists for statuses, modes, and types used across
  schemas, business logic, and templates. Import or alias this module
  instead of hardcoding these values inline.

  For guard clauses and pattern matches, use the module attributes:

      @timestamp_modes Publishing.Constants.timestamp_modes()
      @slug_modes Publishing.Constants.slug_modes()

      def my_func(mode) when mode in @timestamp_modes do ...
  """

  # ---------------------------------------------------------------------------
  # Modes (post and group)
  # ---------------------------------------------------------------------------

  @timestamp_modes [:timestamp, "timestamp"]
  @slug_modes [:slug, "slug"]
  @valid_modes ["timestamp", "slug"]

  @doc "Atom and string variants for timestamp mode — use in guards/pattern matches."
  def timestamp_modes, do: @timestamp_modes

  @doc "Atom and string variants for slug mode — use in guards/pattern matches."
  def slug_modes, do: @slug_modes

  @doc "Valid mode strings for schema validation."
  def valid_modes, do: @valid_modes

  @doc "Returns true if mode is a timestamp mode (atom or string)."
  def timestamp_mode?(mode), do: mode in @timestamp_modes

  @doc "Returns true if mode is a slug mode (atom or string)."
  def slug_mode?(mode), do: mode in @slug_modes

  # ---------------------------------------------------------------------------
  # Statuses
  # ---------------------------------------------------------------------------

  @post_statuses ["draft", "published", "archived", "trashed"]
  @content_statuses ["draft", "published", "archived"]
  @group_statuses ["active", "trashed"]

  @doc "Valid post statuses: draft, published, archived, trashed."
  def post_statuses, do: @post_statuses

  @doc "Valid version and content statuses: draft, published, archived."
  def content_statuses, do: @content_statuses

  @doc "Valid group statuses: active, trashed."
  def group_statuses, do: @group_statuses

  # ---------------------------------------------------------------------------
  # Group types
  # ---------------------------------------------------------------------------

  @preset_types ["blog", "faq", "legal"]
  @valid_types ["blog", "faq", "legal", "custom"]

  @doc "Preset group types (shown as radio buttons in UI)."
  def preset_types, do: @preset_types

  @doc "All valid group types including custom."
  def valid_types, do: @valid_types

  # ---------------------------------------------------------------------------
  # Defaults
  # ---------------------------------------------------------------------------

  @default_mode "timestamp"
  @default_type "blog"

  @doc "Default group mode."
  def default_mode, do: @default_mode

  @doc "Default group type."
  def default_type, do: @default_type
end
