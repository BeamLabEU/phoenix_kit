defmodule PhoenixKit.Modules.Legal.TemplateGenerator do
  @moduledoc """
  Generates legal page content from EEx templates.

  Templates are loaded from:
  1. Parent application's `priv/legal_templates/` (for customization)
  2. PhoenixKit's bundled templates in `priv/legal_templates/`

  ## Template Variables

  All templates receive these variables:
    * `@company_name` - Company name
    * `@company_address` - Company address
    * `@company_country` - Company country
    * `@company_website` - Company website URL
    * `@registration_number` - Company registration number
    * `@vat_number` - VAT number
    * `@dpo_name` - Data Protection Officer name
    * `@dpo_email` - DPO email
    * `@dpo_phone` - DPO phone
    * `@dpo_address` - DPO address
    * `@frameworks` - List of selected framework IDs
    * `@effective_date` - Current date in ISO format

  ## Usage

      context = %{
        company_name: "Acme Corp",
        company_address: "123 Main St",
        effective_date: "2025-01-15"
      }

      {:ok, content} = TemplateGenerator.render("privacy_policy.eex", context)
  """

  require Logger

  @templates_dir "legal_templates"

  @doc """
  Render a template with the given context.

  ## Parameters
    * `template_name` - Template filename (e.g., "privacy_policy.eex")
    * `context` - Map of variables to pass to the template
    * `language` - Language code (default: "en")

  ## Returns
    * `{:ok, content}` - Rendered content
    * `{:error, reason}` - Error reason
  """
  @spec render(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def render(template_name, context, language \\ "en") when is_map(context) do
    template_path = get_template_path(template_name, language)
    context_with_language = Map.put(context, :language, language)

    if File.exists?(template_path) do
      try do
        # Convert context map to keyword list for EEx
        assigns = Enum.map(context_with_language, fn {k, v} -> {to_atom(k), v} end)
        content = EEx.eval_file(template_path, assigns: assigns)
        {:ok, content}
      rescue
        e in EEx.SyntaxError ->
          Logger.error("Template syntax error in #{template_name}: #{inspect(e)}")
          {:error, {:syntax_error, e.message}}

        e ->
          Logger.error("Template rendering error in #{template_name}: #{inspect(e)}")
          {:error, {:render_error, Exception.message(e)}}
      end
    else
      Logger.warning("Template not found: #{template_path}")
      {:error, :template_not_found}
    end
  end

  @doc """
  Get the full path to a template file, with language-aware lookup.

  For a given language, tries `{name}.{lang}.eex` first, then falls back to `{name}.eex`.
  Checks parent application first, then falls back to PhoenixKit templates.
  """
  @spec get_template_path(String.t(), String.t()) :: String.t()
  def get_template_path(template_name, language \\ "en") do
    lang_template_name = localized_template_name(template_name, language)

    # Try language-specific template first (parent app, then PhoenixKit)
    # Fall back to base template (parent app, then PhoenixKit)
    if language != "en" do
      case get_parent_template_path(lang_template_name) do
        {:ok, path} ->
          path

        :error ->
          case get_phoenix_kit_lang_template_path(lang_template_name) do
            {:ok, path} -> path
            :error -> get_base_template_path(template_name)
          end
      end
    else
      get_base_template_path(template_name)
    end
  end

  @doc """
  List all available templates.
  """
  @spec list_available_templates() :: list(String.t())
  def list_available_templates do
    phoenix_kit_templates = list_phoenix_kit_templates()
    parent_templates = list_parent_templates()

    (phoenix_kit_templates ++ parent_templates)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Check if a template exists.
  """
  @spec template_exists?(String.t()) :: boolean()
  def template_exists?(template_name) do
    get_template_path(template_name)
    |> File.exists?()
  end

  # ===================================
  # PRIVATE HELPERS
  # ===================================

  defp localized_template_name(template_name, language) do
    # "privacy_policy.eex" + "de" -> "privacy_policy.de.eex"
    base = Path.rootname(template_name)
    "#{base}.#{language}.eex"
  end

  defp get_base_template_path(template_name) do
    case get_parent_template_path(template_name) do
      {:ok, path} -> path
      :error -> get_phoenix_kit_template_path(template_name)
    end
  end

  defp get_phoenix_kit_lang_template_path(template_name) do
    path = get_phoenix_kit_template_path(template_name)
    if File.exists?(path), do: {:ok, path}, else: :error
  end

  defp get_parent_template_path(template_name) do
    case PhoenixKit.Config.get_parent_app() do
      nil ->
        :error

      app ->
        try do
          priv_dir = Application.app_dir(app, "priv")
          path = Path.join([priv_dir, @templates_dir, template_name])

          if File.exists?(path) do
            {:ok, path}
          else
            :error
          end
        rescue
          _ -> :error
        end
    end
  end

  defp get_phoenix_kit_template_path(template_name) do
    priv_dir = :code.priv_dir(:phoenix_kit) |> to_string()
    Path.join([priv_dir, @templates_dir, template_name])
  rescue
    _ ->
      # Fallback for development
      Path.join(["priv", @templates_dir, template_name])
  end

  defp list_phoenix_kit_templates do
    priv_dir = :code.priv_dir(:phoenix_kit) |> to_string()
    templates_dir = Path.join(priv_dir, @templates_dir)

    if File.dir?(templates_dir) do
      templates_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".eex"))
    else
      []
    end
  rescue
    _ -> []
  end

  defp list_parent_templates do
    case PhoenixKit.Config.get_parent_app() do
      nil ->
        []

      app ->
        try do
          priv_dir = Application.app_dir(app, "priv")
          templates_dir = Path.join(priv_dir, @templates_dir)

          if File.dir?(templates_dir) do
            templates_dir
            |> File.ls!()
            |> Enum.filter(&String.ends_with?(&1, ".eex"))
          else
            []
          end
        rescue
          _ -> []
        end
    end
  end

  defp to_atom(key) when is_atom(key), do: key
  defp to_atom(key) when is_binary(key), do: String.to_atom(key)
end
