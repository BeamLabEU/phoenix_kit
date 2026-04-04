defmodule PhoenixKit.Modules.LLMText do
  @moduledoc """
  LLM Text module for PhoenixKit.

  Generates LLM-friendly text files (llms.txt + per-page .txt files)
  from configured sources, served at `/llms.txt` and `/llms/*path`.

  ## Settings keys

  - `llm_text_enabled` — enable/disable the module (boolean, default: false)

  ## Configuration

  Configure sources in the host app:

      config :phoenix_kit, :llm_text_sources, [
        PhoenixKit.Modules.LLMText.Sources.Publishing
      ]

  ## Usage

      # Check if enabled
      PhoenixKit.Modules.LLMText.enabled?()

      # Regenerate all files
      PhoenixKit.Modules.LLMText.Generator.run_all()
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Modules.LLMText.Generator
  alias PhoenixKit.Modules.LLMText.PublishingSubscriber

  @enabled_key "llm_text_enabled"

  # ── Required Module callbacks ──────────────────────────────────────

  @impl PhoenixKit.Module
  def module_key, do: "llm_text"

  @impl PhoenixKit.Module
  def module_name, do: "LLM Text"

  @impl PhoenixKit.Module
  def enabled? do
    settings_call(:get_boolean_setting, [@enabled_key, false])
  end

  @impl PhoenixKit.Module
  def enable_system do
    settings_call(:update_boolean_setting, [@enabled_key, true])
  end

  @impl PhoenixKit.Module
  def disable_system do
    settings_call(:update_boolean_setting, [@enabled_key, false])
  end

  # ── Optional Module callbacks ──────────────────────────────────────

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "llm_text",
      label: "LLM Text",
      icon: "hero-document-text",
      description: "Generate LLM-friendly text files (llms.txt) for AI consumption"
    }
  end

  @impl PhoenixKit.Module
  def get_config do
    %{
      enabled: enabled?(),
      sources: Generator.get_sources()
    }
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      Tab.new!(
        id: :admin_settings_llm_text,
        label: "LLM Text",
        icon: "hero-document-text",
        path: "llm-text",
        priority: 935,
        level: :admin,
        parent: :admin_settings,
        permission: "llm_text"
      )
    ]
  end

  @impl PhoenixKit.Module
  def children do
    if enabled?() do
      [PublishingSubscriber]
    else
      []
    end
  end

  # ── Private helpers ────────────────────────────────────────────────

  defp settings_module do
    PhoenixKit.Config.get(:llm_text_settings_module, PhoenixKit.Settings)
  end

  defp settings_call(fun, args) do
    apply(settings_module(), fun, args)
  end
end
