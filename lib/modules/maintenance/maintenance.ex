defmodule PhoenixKit.Modules.Maintenance do
  @moduledoc """
  Maintenance Mode module for PhoenixKit.

  This module provides a system-wide maintenance mode that shows a
  maintenance page to all non-admin users while allowing
  admins and owners to access the site normally.

  ## Settings

  The module uses the following settings stored in the database:
  - `maintenance_module_enabled` - Boolean to enable/disable the module settings page (default: false)
  - `maintenance_enabled` - Boolean to enable/disable maintenance mode (default: false)
  - `maintenance_header` - Main heading text (default: "Maintenance Mode")
  - `maintenance_subtext` - Descriptive subtext (default: "We'll be back soon")

  ## Usage

      # Check if module is enabled (settings page accessible)
      if PhoenixKit.Modules.Maintenance.module_enabled?() do
        # Show settings page
      end

      # Check if maintenance mode is enabled
      if PhoenixKit.Modules.Maintenance.enabled?() do
        # Show maintenance page to non-admin users
      end

      # Enable module (makes settings page accessible)
      PhoenixKit.Modules.Maintenance.enable_module()

      # Enable maintenance mode (shows maintenance page to users)
      PhoenixKit.Modules.Maintenance.enable_system()

      # Get module configuration
      config = PhoenixKit.Modules.Maintenance.get_config()
      # => %{module_enabled: true, enabled: true, header: "...", subtext: "..."}
  """

  alias PhoenixKit.Settings

  @default_header "Maintenance Mode"
  @default_subtext "We'll be back soon. Our team is working hard to bring you something amazing!"

  @doc """
  Checks if the Maintenance module is enabled (settings page accessible).

  ## Examples

      iex> PhoenixKit.Modules.Maintenance.module_enabled?()
      false
  """
  def module_enabled? do
    Settings.get_boolean_setting("maintenance_module_enabled", false)
  end

  @doc """
  Enables the Maintenance module (makes settings page accessible).
  """
  def enable_module do
    Settings.update_boolean_setting("maintenance_module_enabled", true)
  end

  @doc """
  Disables the Maintenance module (hides settings page).

  Also automatically disables maintenance mode to prevent users from being locked out.
  """
  def disable_module do
    # First disable maintenance mode
    disable_system()

    # Then disable the module (hides settings page)
    Settings.update_boolean_setting("maintenance_module_enabled", false)
  end

  @doc """
  Checks if Maintenance mode is enabled.

  ## Examples

      iex> PhoenixKit.Modules.Maintenance.enabled?()
      false
  """
  def enabled? do
    Settings.get_boolean_setting("maintenance_enabled", false)
  end

  @doc """
  Enables the Maintenance mode.

  When enabled, all non-admin users will see the maintenance page.
  """
  def enable_system do
    Settings.update_boolean_setting("maintenance_enabled", true)
  end

  @doc """
  Disables the Maintenance mode.

  When disabled, all users can access the site normally.
  """
  def disable_system do
    Settings.update_boolean_setting("maintenance_enabled", false)
  end

  @doc """
  Gets the header text for the maintenance page.

  ## Examples

      iex> PhoenixKit.Modules.Maintenance.get_header()
      "Maintenance Mode"
  """
  def get_header do
    Settings.get_setting("maintenance_header", @default_header)
  end

  @doc """
  Updates the header text for the maintenance page.
  """
  def update_header(header) when is_binary(header) do
    Settings.update_setting("maintenance_header", header)
  end

  @doc """
  Gets the subtext for the maintenance page.

  ## Examples

      iex> PhoenixKit.Modules.Maintenance.get_subtext()
      "We'll be back soon..."
  """
  def get_subtext do
    Settings.get_setting("maintenance_subtext", @default_subtext)
  end

  @doc """
  Updates the subtext for the maintenance page.
  """
  def update_subtext(subtext) when is_binary(subtext) do
    Settings.update_setting("maintenance_subtext", subtext)
  end

  @doc """
  Gets the configuration for the Maintenance module.

  Returns a map with:
  - `module_enabled` - Boolean indicating if module settings page is accessible
  - `enabled` - Boolean indicating if maintenance mode is enabled
  - `header` - Main heading text
  - `subtext` - Descriptive subtext

  ## Examples

      iex> PhoenixKit.Modules.Maintenance.get_config()
      %{
        module_enabled: false,
        enabled: false,
        header: "Maintenance Mode",
        subtext: "We'll be back soon..."
      }
  """
  def get_config do
    %{
      module_enabled: module_enabled?(),
      enabled: enabled?(),
      header: get_header(),
      subtext: get_subtext()
    }
  end
end
