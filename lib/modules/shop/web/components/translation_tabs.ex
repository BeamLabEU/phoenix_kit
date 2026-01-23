defmodule PhoenixKit.Modules.Shop.Web.Components.TranslationTabs do
  @moduledoc """
  Translation tabs component for Shop module forms.

  Displays language tabs for editing product/category translations.
  Only visible when the Languages module is enabled and has multiple languages.

  ## Localized Fields Model

  With the new localized fields approach, each translatable field stores
  a map of language → value directly:

      %Product{
        title: %{"en" => "Planter", "ru" => "Кашпо"},
        slug: %{"en" => "planter", "ru" => "kashpo"}
      }

  The component provides helpers to work with this structure in forms.

  ## Examples

      <.translation_tabs
        languages={@enabled_languages}
        current_language={@current_language}
        entity={@product}
        translatable_fields={[:title, :slug, :description]}
        on_click="switch_language"
      />
  """

  use Phoenix.Component

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Shop.Translations

  @doc """
  Renders translation tabs for multi-language editing.

  ## Attributes

  - `languages` - List of language maps with keys: `code`, `name`, `flag`
  - `current_language` - Currently active language code
  - `translations` - Current translations map from entity
  - `translatable_fields` - List of field atoms that should be translated
  - `on_click` - Event name for tab click handler
  - `class` - Additional CSS classes
  """
  attr :languages, :list, required: true
  attr :current_language, :string, required: true
  attr :translations, :map, default: %{}
  attr :translatable_fields, :list, default: []
  attr :on_click, :string, default: "switch_language"
  attr :class, :string, default: ""

  def translation_tabs(assigns) do
    # Calculate translation status for each language
    languages_with_status =
      Enum.map(assigns.languages, fn lang ->
        code = lang["code"] || lang[:code]
        status = calculate_status(assigns.translations, code, assigns.translatable_fields)
        Map.put(lang, :status, status)
      end)

    assigns = assign(assigns, :languages_with_status, languages_with_status)

    ~H"""
    <div class={["tabs tabs-bordered", @class]}>
      <%= for lang <- @languages_with_status do %>
        <% code = lang["code"] || lang[:code] %>
        <% name = lang["name"] || lang[:name] || code %>
        <% is_current = code == @current_language %>
        <% is_default = lang["is_default"] || lang[:is_default] || false %>
        <button
          type="button"
          phx-click={@on_click}
          phx-value-language={code}
          class={[
            "tab gap-2",
            is_current && "tab-active"
          ]}
        >
          <span class={[
            is_default && "font-bold",
            !is_current && "opacity-70"
          ]}>
            {format_display_name(name, code)}
          </span>
          <.status_badge status={lang.status} is_default={is_default} />
        </button>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders translation fields for the current language.

  ## Attributes

  - `language` - Current language code being edited
  - `translations` - Current translations map from entity
  - `fields` - List of field configs: `[%{key: :title, label: "Title", type: :text}, ...]`
  - `form_prefix` - Form name prefix (e.g., "product")
  """
  attr :language, :string, required: true
  attr :translations, :map, default: %{}
  attr :fields, :list, required: true
  attr :form_prefix, :string, required: true
  attr :is_default_language, :boolean, default: false

  def translation_fields(assigns) do
    current_translation = Map.get(assigns.translations, assigns.language, %{})
    assigns = assign(assigns, :current_translation, current_translation)

    ~H"""
    <div class="space-y-4">
      <%= if @is_default_language do %>
        <div class="alert alert-info text-sm py-2">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
            class="stroke-current shrink-0 w-5 h-5"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
            >
            </path>
          </svg>
          <span>This is the default language. Edit the main fields above for canonical content.</span>
        </div>
      <% else %>
        <%= for field <- @fields do %>
          <.translation_field
            field={field}
            language={@language}
            value={Map.get(@current_translation, to_string(field.key), "")}
            form_prefix={@form_prefix}
          />
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :field, :map, required: true
  attr :language, :string, required: true
  attr :value, :string, default: ""
  attr :form_prefix, :string, required: true

  defp translation_field(assigns) do
    field_name = "#{assigns.form_prefix}[translations][#{assigns.language}][#{assigns.field.key}]"
    assigns = assign(assigns, :field_name, field_name)

    ~H"""
    <div class="form-control w-full">
      <label class="label">
        <span class="label-text font-medium">{@field.label}</span>
        <span class="label-text-alt text-base-content/50">{String.upcase(@language)}</span>
      </label>
      <%= case @field.type do %>
        <% :textarea -> %>
          <textarea
            name={@field_name}
            class="textarea textarea-bordered w-full h-24 focus:textarea-primary"
            placeholder={@field[:placeholder] || ""}
          >{@value}</textarea>
        <% :html -> %>
          <textarea
            name={@field_name}
            class="textarea textarea-bordered w-full h-32 focus:textarea-primary font-mono text-sm"
            placeholder={@field[:placeholder] || "HTML content..."}
          >{@value}</textarea>
        <% _ -> %>
          <input
            type="text"
            name={@field_name}
            value={@value}
            class="input input-bordered w-full focus:input-primary"
            placeholder={@field[:placeholder] || ""}
          />
      <% end %>
      <%= if @field[:hint] do %>
        <label class="label py-1">
          <span class="label-text-alt text-base-content/50">{@field.hint}</span>
        </label>
      <% end %>
    </div>
    """
  end

  # Status badge showing translation completeness
  attr :status, :map, required: true
  attr :is_default, :boolean, default: false

  defp status_badge(assigns) do
    ~H"""
    <%= cond do %>
      <% @is_default -> %>
        <span class="badge badge-primary badge-xs">Default</span>
      <% @status.percentage == 100 -> %>
        <span class="badge badge-success badge-xs">✓</span>
      <% @status.percentage > 0 -> %>
        <span class="badge badge-warning badge-xs">{@status.percentage}%</span>
      <% true -> %>
        <span class="badge badge-ghost badge-xs">—</span>
    <% end %>
    """
  end

  defp format_display_name(name, code) do
    # Extract base language name, removing region part
    base_name =
      name
      |> String.split("(")
      |> List.first()
      |> String.trim()

    # If name is same as code, use code uppercase
    if String.downcase(base_name) == String.downcase(code) do
      String.upcase(code)
    else
      base_name
    end
  end

  defp calculate_status(translations, language, fields) when is_list(fields) do
    translation = Map.get(translations || %{}, language, %{})

    present =
      Enum.count(fields, fn field ->
        value = Map.get(translation, to_string(field))
        value != nil and value != ""
      end)

    total = length(fields)

    %{
      complete: present,
      total: total,
      percentage: if(total > 0, do: round(present / total * 100), else: 0)
    }
  end

  defp calculate_status(_, _, _), do: %{complete: 0, total: 0, percentage: 0}

  # ============================================================================
  # Helper Functions
  # ============================================================================

  @doc """
  Returns list of enabled languages for translation tabs.

  Returns empty list if Languages module is disabled or only one language enabled.
  """
  @spec get_enabled_languages() :: [map()]
  def get_enabled_languages do
    if languages_enabled?() do
      Languages.get_enabled_languages()
    else
      []
    end
  end

  @doc """
  Returns the default language code.
  """
  @spec get_default_language() :: String.t()
  def get_default_language do
    Translations.default_language()
  end

  @doc """
  Checks if multi-language editing should be shown.

  Returns true if Languages module is enabled and has 2+ languages.
  """
  @spec show_translation_tabs?() :: boolean()
  def show_translation_tabs? do
    if languages_enabled?() do
      length(Languages.get_enabled_language_codes()) > 1
    else
      false
    end
  end

  # ============================================================================
  # Localized Fields Helpers
  # ============================================================================

  @doc """
  Gets the value of a localized field for a specific language.

  Works with the new localized fields model where each field is a map.

  ## Examples

      iex> get_localized_value(%Product{title: %{"en" => "Planter", "ru" => "Кашпо"}}, :title, "en")
      "Planter"

      iex> get_localized_value(%Product{title: %{"en" => "Planter"}}, :title, "ru")
      nil
  """
  @spec get_localized_value(struct() | Ecto.Changeset.t(), atom(), String.t()) ::
          String.t() | nil
  def get_localized_value(%Ecto.Changeset{} = changeset, field, language) do
    field_map = Ecto.Changeset.get_field(changeset, field) || %{}
    Map.get(field_map, language)
  end

  def get_localized_value(entity, field, language) when is_struct(entity) do
    field_map = Map.get(entity, field) || %{}
    Map.get(field_map, language)
  end

  def get_localized_value(_, _, _), do: nil

  @doc """
  Builds a translations map from entity's localized fields.

  Transforms from new model (field → lang → value) to UI model (lang → field → value).
  This allows the TranslationTabs UI to work with the new localized fields model.

  ## Examples

      iex> entity = %Product{
      ...>   title: %{"en" => "Planter", "ru" => "Кашпо"},
      ...>   slug: %{"en" => "planter", "ru" => "kashpo"}
      ...> }
      iex> build_translations_map(entity, [:title, :slug])
      %{
        "en" => %{"title" => "Planter", "slug" => "planter"},
        "ru" => %{"title" => "Кашпо", "slug" => "kashpo"}
      }
  """
  @spec build_translations_map(struct(), [atom()]) :: map()
  def build_translations_map(entity, fields) when is_struct(entity) and is_list(fields) do
    # Get all languages present in any field
    all_languages =
      fields
      |> Enum.flat_map(fn field ->
        field_map = Map.get(entity, field) || %{}
        Map.keys(field_map)
      end)
      |> Enum.uniq()

    # Build translations map: lang => {field => value}
    Enum.reduce(all_languages, %{}, fn lang, acc ->
      field_values =
        Enum.reduce(fields, %{}, fn field, field_acc ->
          field_map = Map.get(entity, field) || %{}
          value = Map.get(field_map, lang)

          if value do
            Map.put(field_acc, to_string(field), value)
          else
            field_acc
          end
        end)

      if field_values != %{} do
        Map.put(acc, lang, field_values)
      else
        acc
      end
    end)
  end

  def build_translations_map(_, _), do: %{}

  @doc """
  Merges translations map back into localized field attrs for changeset.

  Transforms from UI model (lang → field → value) to new model attrs.

  ## Parameters

    - `entity` - The current entity (to preserve existing values)
    - `translations_map` - UI translations map
    - `default_lang_values` - Values from main form fields (for default language)
    - `fields` - List of translatable field atoms

  ## Examples

      iex> merge_translations_to_attrs(
      ...>   %Product{title: %{"en" => "Old"}, slug: %{"en" => "old"}},
      ...>   %{"ru" => %{"title" => "Кашпо", "slug" => "kashpo"}},
      ...>   %{"title" => "New Planter", "slug" => "new-planter"},
      ...>   "en",
      ...>   [:title, :slug]
      ...> )
      %{
        title: %{"en" => "New Planter", "ru" => "Кашпо"},
        slug: %{"en" => "new-planter", "ru" => "kashpo"}
      }
  """
  @spec merge_translations_to_attrs(struct(), map(), map(), String.t(), [atom()]) :: map()
  def merge_translations_to_attrs(entity, translations_map, default_values, default_lang, fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      # Start with existing field values
      existing = Map.get(entity, field) || %{}

      # Add default language value from main form
      field_str = to_string(field)

      updated = merge_field_value(existing, default_lang, default_values, field_str)

      # Merge translations from other languages
      updated =
        Enum.reduce(translations_map, updated, fn {lang, field_values}, field_acc ->
          merge_field_value(field_acc, lang, field_values, field_str)
        end)

      Map.put(acc, field, updated)
    end)
  end

  # Helper to merge a single field value, reducing nesting depth
  defp merge_field_value(field_acc, lang, field_values, field_str) do
    case Map.fetch(field_values, field_str) do
      {:ok, value} when is_binary(value) and value != "" ->
        Map.put(field_acc, lang, value)

      {:ok, _empty_value} ->
        Map.delete(field_acc, lang)

      :error ->
        field_acc
    end
  end

  defp languages_enabled? do
    Code.ensure_loaded?(Languages) and Languages.enabled?()
  end
end
