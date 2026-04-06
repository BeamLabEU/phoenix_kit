defmodule PhoenixKit.Install.LlmTextConfig do
  @moduledoc """
  Handles LLMText sources configuration for PhoenixKit installation and updates.

  Ensures that `sitemap_llm_text_sources` is configured in the parent app's
  config/config.exs with the Publishing source as a minimum.
  """

  @doc """
  Checks if `sitemap_llm_text_sources` is already configured in config.exs.
  """
  @spec llm_text_sources_config_exists?() :: boolean()
  def llm_text_sources_config_exists? do
    config_path = "config/config.exs"

    if File.exists?(config_path) do
      content = File.read!(config_path)

      String.contains?(content, "sitemap_llm_text_sources")
    else
      false
    end
  rescue
    _ -> false
  end

  @doc """
  Adds the `sitemap_llm_text_sources` configuration to config.exs if not present.

  Returns `:ok` if config was added or already existed, `{:error, reason}` on failure.
  """
  @spec ensure_llm_text_sources_config() :: :ok | {:error, String.t()}
  def ensure_llm_text_sources_config do
    if llm_text_sources_config_exists?() do
      :ok
    else
      add_llm_text_sources_config()
    end
  end

  @doc """
  Adds `sitemap_llm_text_sources` config to config.exs via Igniter source update.

  Accepts an Igniter struct and returns the updated Igniter.
  """
  @spec ensure_llm_text_sources_config(igniter :: term()) :: term()
  def ensure_llm_text_sources_config(igniter) do
    if llm_text_sources_config_exists?() do
      igniter
    else
      add_llm_text_sources_config_via_igniter(igniter)
    end
  end

  # Private helpers

  defp add_llm_text_sources_config do
    config_path = "config/config.exs"

    if File.exists?(config_path) do
      content = File.read!(config_path)
      updated = content <> llm_text_config_snippet()
      File.write!(config_path, updated)
      :ok
    else
      {:error, "config/config.exs not found"}
    end
  rescue
    e -> {:error, inspect(e)}
  end

  defp add_llm_text_sources_config_via_igniter(igniter) do
    Igniter.update_file(igniter, "config/config.exs", fn source ->
      content = Rewrite.Source.get(source, :content)

      updated_content =
        if String.contains?(content, "sitemap_llm_text_sources") do
          content
        else
          content <> llm_text_config_snippet()
        end

      Rewrite.Source.update(source, :content, updated_content)
    end)
  rescue
    _ -> igniter
  end

  defp llm_text_config_snippet do
    """

    # LLM-friendly text generation sources (llms.txt)
    # Add PhoenixKit.Modules.Sitemap.LLMText.Sources.Shop if using phoenix_kit_ecommerce
    config :phoenix_kit, :sitemap_llm_text_sources, [
      PhoenixKit.Modules.Sitemap.LLMText.Sources.Publishing
    ]
    """
  end
end
