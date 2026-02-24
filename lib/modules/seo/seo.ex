defmodule PhoenixKit.Modules.SEO do
  @moduledoc """
  SEO module for PhoenixKit.

  Provides project-wide search visibility controls. Currently supports a
  `noindex, nofollow` directive for staging environments, and will be extended
  with additional SEO options in the future.
  """
  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings

  @module_enabled_key "seo_module_enabled"
  @no_index_key "seo_no_index"
  @module_name "seo"

  @doc """
  Indicates whether the SEO module is available in the admin.
  """
  def module_enabled? do
    Settings.get_boolean_setting(@module_enabled_key, false)
  end

  @doc """
  Enables the SEO module (exposes the settings page).
  """
  def enable_module do
    Settings.update_boolean_setting_with_module(@module_enabled_key, true, @module_name)
  end

  @doc """
  Disables the SEO module and clears any active directives.
  """
  def disable_module do
    case Settings.update_boolean_setting_with_module(@module_enabled_key, false, @module_name) do
      {:ok, _setting} = result ->
        # Ensure site becomes indexable once the module is disabled
        _ = update_no_index(false)
        result

      {:error, _changeset} = error ->
        error
    end
  end

  @doc """
  Returns true when the `noindex, nofollow` directive is active.
  """
  def no_index_enabled? do
    Settings.get_boolean_setting(@no_index_key, false)
  end

  @doc """
  Enables the global `noindex, nofollow` directive.
  """
  def enable_no_index do
    update_no_index(true)
  end

  @doc """
  Disables the global `noindex, nofollow` directive.
  """
  def disable_no_index do
    update_no_index(false)
  end

  @doc """
  Updates the directive to the provided boolean value.
  """
  def update_no_index(enabled?) when is_boolean(enabled?) do
    Settings.update_boolean_setting_with_module(@no_index_key, enabled?, @module_name)
  end

  @impl PhoenixKit.Module
  @doc """
  Returns configuration metadata for dashboard cards and settings pages.
  """
  def get_config do
    %{
      module_enabled: module_enabled?(),
      no_index_enabled: no_index_enabled?()
    }
  end

  # ============================================================================
  # Module Behaviour Callbacks
  # ============================================================================

  @impl PhoenixKit.Module
  def module_key, do: "seo"

  @impl PhoenixKit.Module
  def module_name, do: "SEO"

  @impl PhoenixKit.Module
  def enabled?, do: module_enabled?()

  @impl PhoenixKit.Module
  def enable_system, do: enable_module()

  @impl PhoenixKit.Module
  def disable_system, do: disable_module()

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "seo",
      label: "SEO",
      icon: "hero-magnifying-glass",
      description: "Meta tags, Open Graph, and search optimization"
    }
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      Tab.new!(
        id: :admin_settings_seo,
        label: "SEO",
        icon: "hero-magnifying-glass-circle",
        path: "/admin/settings/seo",
        priority: 930,
        level: :admin,
        parent: :admin_settings,
        permission: "seo"
      )
    ]
  end
end
