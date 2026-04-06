defmodule Mix.Tasks.PhoenixKit.LlmText.Setup do
  @moduledoc """
  Sets up LLMText (llms.txt) for the parent application.

  ## Usage

      mix phoenix_kit.llm_text.setup

  This will:
  1. Add `sitemap_llm_text_sources` config to config.exs (auto-detects Shop)
  2. Enable the LLMText module in the database
  3. Run initial generation of llms.txt and page files
  4. Verify site_name setting

  ## Options

      --config-only    Only add config, don't enable or generate
      --skip-generate  Add config and enable, but skip initial generation
  """

  use Mix.Task

  @shortdoc "Set up LLMText (llms.txt) for the parent application"

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [config_only: :boolean, skip_generate: :boolean])

    config_only? = Keyword.get(opts, :config_only, false)
    skip_generate? = Keyword.get(opts, :skip_generate, false)

    # Step 1: Config
    setup_config()

    unless config_only? do
      # Need running app for DB and generation
      Mix.Task.run("app.start")

      # Step 2: Enable module
      enable_module()

      # Step 3: Check site_name
      check_site_name()

      # Step 4: Generate
      unless skip_generate? do
        generate_files()
      end

      # Step 5: Summary
      print_summary()
    end
  end

  defp setup_config do
    config_path = "config/config.exs"

    unless File.exists?(config_path) do
      Mix.shell().error("❌ config/config.exs not found. Run from your Phoenix app root.")
      exit({:shutdown, 1})
    end

    content = File.read!(config_path)

    if String.contains?(content, "sitemap_llm_text_sources") do
      Mix.shell().info("✅ sitemap_llm_text_sources already configured")
    else
      has_ecommerce? = ecommerce_dep_present?()
      snippet = build_config_snippet(has_ecommerce?)
      File.write!(config_path, content <> snippet)

      Mix.shell().info("✅ Added sitemap_llm_text_sources to config/config.exs")

      if has_ecommerce? do
        Mix.shell().info("   Shop source included (ecommerce detected)")
      end
    end
  end

  defp enable_module do
    if Code.ensure_loaded?(PhoenixKit.Modules.Sitemap) do
      case PhoenixKit.Settings.get_boolean_setting("sitemap_enabled", false) do
        true ->
          Mix.shell().info("✅ Sitemap module already enabled")

        false ->
          PhoenixKit.Settings.update_boolean_setting("sitemap_enabled", true)
          Mix.shell().info("✅ Enabled Sitemap module")
      end
    end
  rescue
    error ->
      Mix.shell().error("⚠️  Could not enable module: #{inspect(error)}")

      Mix.shell().info(
        "   Run in iex: PhoenixKit.Settings.update_boolean_setting(\"sitemap_enabled\", true)"
      )
  end

  defp check_site_name do
    site_name = PhoenixKit.Settings.get_setting("site_name")

    if site_name && site_name != "" do
      Mix.shell().info("✅ site_name: #{site_name}")
    else
      Mix.shell().info(
        "⚠️  site_name not set — llms.txt header will show \"# Site\".\n" <>
          "   Set it in admin Settings or run:\n" <>
          "   PhoenixKit.Settings.update_setting(\"site_name\", \"Your Site Name\")"
      )
    end
  rescue
    _ ->
      Mix.shell().info("⚠️  Could not check site_name setting")
  end

  defp generate_files do
    alias PhoenixKit.Modules.Sitemap.LLMText.Generator

    sources = Generator.get_sources()

    if sources == [] do
      Mix.shell().info(
        "⚠️  No sources configured. Restart your app to pick up config changes,\n" <>
          "   then run: PhoenixKit.Modules.Sitemap.LLMText.Generator.run_all()"
      )
    else
      Mix.shell().info("⏳ Generating llms.txt from #{length(sources)} source(s)...")

      Generator.run_all()

      alias PhoenixKit.Modules.Sitemap.LLMText.FileStorage
      index = FileStorage.index_path()

      if File.exists?(index) do
        size = File.stat!(index).size
        Mix.shell().info("✅ Generated llms.txt (#{div(size, 1024)} KB)")

        # Count generated files
        dir = FileStorage.storage_dir()

        {output, 0} = System.cmd("find", [dir, "-type", "f", "-name", "*.txt"])
        file_count = output |> String.split("\n", trim: true) |> length()
        Mix.shell().info("   #{file_count} file(s) in #{dir}")
      else
        Mix.shell().info("⚠️  Generation completed but index file not found at #{index}")
      end
    end
  rescue
    error ->
      Mix.shell().error("⚠️  Generation failed: #{inspect(error)}")

      Mix.shell().info(
        "   Run manually in iex: PhoenixKit.Modules.Sitemap.LLMText.Generator.run_all()"
      )
  end

  defp print_summary do
    Mix.shell().info("""

    ── LLMText Setup Complete ──────────────────────────

    Your site now serves:
      GET /llms.txt         — index of all LLM-readable pages
      GET /llms/*path       — individual page files

    Sources are auto-refreshed via Oban when Publishing
    content changes. To manually regenerate:

      PhoenixKit.Modules.Sitemap.LLMText.Generator.run_all()

    ────────────────────────────────────────────────────
    """)
  end

  defp ecommerce_dep_present? do
    Mix.Project.deps_paths()
    |> Map.has_key?(:phoenix_kit_ecommerce)
  rescue
    _ -> false
  end

  defp build_config_snippet(has_ecommerce?) do
    sources =
      [
        "PhoenixKit.Modules.Sitemap.LLMText.Sources.Publishing",
        if(has_ecommerce?, do: "PhoenixKit.Modules.Sitemap.LLMText.Sources.Shop")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(",\n  ", & &1)

    """

    # LLM-friendly text generation sources (llms.txt)
    # See: https://llmstxt.org
    config :phoenix_kit, :sitemap_llm_text_sources, [
      #{sources}
    ]
    """
  end
end
