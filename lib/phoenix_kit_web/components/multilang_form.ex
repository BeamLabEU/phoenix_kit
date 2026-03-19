defmodule PhoenixKitWeb.Components.MultilangForm do
  @moduledoc """
  Shared multilang form components and helpers for PhoenixKit modules.

  Provides the language tab switcher UI, skeleton loading placeholders,
  translatable field components, and Elixir-side helpers for merging
  multilang data in LiveView forms.

  Designed for two main use cases:

  1. **Whole-form translation** — wrap all translatable fields in a card with
     language tabs. The tab bar, skeleton placeholders, and field wrappers
     are handled automatically.

  2. **Single-field translation** — drop a `<.translatable_field>` into any
     form to make one field translatable, with no tab UI required (the caller
     manages `current_lang` however they like).

  ## Usage in a LiveView

  ### Mount

      import PhoenixKitWeb.Components.MultilangForm

      def mount(params, session, socket) do
        # ... load your record and changeset ...
        {:ok, mount_multilang(socket)}
      end

  ### Events

      def handle_event("switch_language", %{"lang" => lang_code}, socket) do
        {:noreply, handle_switch_language(socket, lang_code)}
      end

      def handle_event("validate", %{"record" => params}, socket) do
        params = merge_translatable_params(params, socket, ["name", "description"],
          changeset: socket.assigns.changeset)
        changeset = MySchema.changeset(socket.assigns.record, params)
        {:noreply, assign(socket, :changeset, changeset)}
      end

  ### Template — whole-form translation

      <.multilang_tabs
        multilang_enabled={@multilang_enabled}
        language_tabs={@language_tabs}
        current_lang={@current_lang}
      />

      <.multilang_fields_wrapper
        multilang_enabled={@multilang_enabled}
        current_lang={@current_lang}
      >
        <.translatable_field
          field_name="name"
          form_prefix="catalogue"
          changeset={@changeset}
          schema_field={:name}
          multilang_enabled={@multilang_enabled}
          current_lang={@current_lang}
          primary_language={@primary_language}
          lang_data={@lang_data}
          label={gettext("Name")}
          required
        />
      </.multilang_fields_wrapper>

  ### Template — single-field translation (no tabs needed)

      <.translatable_field
        field_name="description"
        form_prefix="product"
        changeset={@changeset}
        schema_field={:description}
        multilang_enabled={@multilang_enabled}
        current_lang={@current_lang}
        primary_language={@primary_language}
        lang_data={@lang_data}
        label={gettext("Description")}
        type="textarea"
        rows={5}
      />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.FormFieldError, only: [error: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [translate_error: 1]
  import PhoenixKitWeb.Components.LanguageSwitcher, only: [language_switcher: 1]

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Modules.Entities.Multilang

  # ═══════════════════════════════════════════════════════════════════
  # Mount & Event Helpers
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Adds multilang assigns to the socket. Call from `mount/3`.

  Adds: `:multilang_enabled`, `:primary_language`, `:current_lang`, `:language_tabs`
  """
  def mount_multilang(socket) do
    multilang_enabled = multilang_enabled?()
    primary_language = if multilang_enabled, do: safe_primary_language(), else: nil

    Phoenix.Component.assign(socket,
      multilang_enabled: multilang_enabled,
      primary_language: primary_language,
      current_lang: primary_language,
      language_tabs: if(multilang_enabled, do: safe_build_language_tabs(), else: [])
    )
  end

  @doc """
  Refreshes multilang assigns after external changes (e.g. entity schema update).

  Unlike `mount_multilang/1`, this preserves `current_lang` when it's still valid,
  and resets it to the primary language if it was removed.
  """
  def refresh_multilang(socket) do
    multilang_enabled = multilang_enabled?()
    primary_language = if multilang_enabled, do: safe_primary_language(), else: nil
    language_tabs = if multilang_enabled, do: safe_build_language_tabs(), else: []

    current_lang = socket.assigns[:current_lang]
    enabled_langs = if multilang_enabled, do: safe_enabled_languages(), else: []

    current_lang =
      cond do
        not multilang_enabled -> nil
        current_lang not in enabled_langs -> primary_language
        true -> current_lang
      end

    Phoenix.Component.assign(socket,
      multilang_enabled: multilang_enabled,
      primary_language: primary_language,
      current_lang: current_lang,
      language_tabs: language_tabs
    )
  end

  @doc """
  Handles the `"switch_language"` event. Call from `handle_event/3`.

  Returns the updated socket with the new `current_lang`.
  Ignores unknown language codes.
  """
  def handle_switch_language(socket, lang_code) do
    if lang_code in safe_enabled_languages() do
      Phoenix.Component.assign(socket, :current_lang, lang_code)
    else
      socket
    end
  end

  @doc """
  Merges translatable field params into the multilang `data` JSONB structure.

  Takes the raw form params, the socket, and a list of translatable field names
  (the DB column names, e.g. `["name", "description"]`). Returns updated params
  with the `"data"` key set to the merged multilang structure.

  On primary language tabs, reads from `params["name"]`.
  On secondary language tabs, reads from `params["lang_name"]`.

  Also preserves primary language values for non-translatable fields when on
  secondary tabs via the `preserve_fields` option.

  ## Options

    * `:changeset` — the current changeset (required)
    * `:preserve_fields` — map of `%{"field_name" => :schema_field}` for fields
      that should keep their primary language DB column value on secondary tabs.
      Defaults to `%{}`.
  """
  def merge_translatable_params(params, socket, translatable_fields, opts \\ []) do
    changeset = Keyword.fetch!(opts, :changeset)
    preserve_fields = Keyword.get(opts, :preserve_fields, %{})
    assigns = socket.assigns
    current_lang = assigns[:current_lang]
    primary = assigns[:primary_language]

    params =
      if assigns[:multilang_enabled] do
        form_data = extract_translatable_data(params, translatable_fields, current_lang, primary)
        final_data = do_merge_multilang_data(changeset, current_lang, form_data, assigns)
        Map.put(params, "data", final_data)
      else
        params
      end

    do_preserve_primary_fields(params, changeset, assigns, preserve_fields)
  end

  @doc """
  Injects a DB column value into the JSONB `data` field for multilang storage.

  This handles the common pattern where a field exists both as a top-level DB
  column (for queries/sorting) and inside the JSONB `data` (for translations).

  On the primary language tab, reads from `params[field_name]` (the DB column input).
  On secondary language tabs, reads from `params["lang_" <> field_name]` (the translation input).

  The value is stored in the data map under `"_" <> field_name` (e.g. `"_title"`).

  If no value is submitted (field not in form), preserves the existing value from
  the changeset's JSONB data.

  ## Requirements

  `assigns` must contain:
  - `:multilang_enabled` — boolean
  - `:primary_language` — the primary language code
  - `:changeset` — an `Ecto.Changeset` with a `:data` field (JSONB)

  ## Examples

      # In handle_event("validate", ...)
      form_data =
        form_data
        |> inject_db_field_into_data("title", data_params, current_lang, socket.assigns)
        |> inject_db_field_into_data("slug", data_params, current_lang, socket.assigns)
  """
  def inject_db_field_into_data(form_data, field_name, params, current_lang, assigns) do
    if assigns[:multilang_enabled] == true do
      primary = assigns[:primary_language]

      value =
        if current_lang == primary,
          do: params[field_name],
          else: params["lang_#{field_name}"]

      data_key = "_#{field_name}"

      if is_binary(value) do
        Map.put(form_data, data_key, value)
      else
        # No value submitted — preserve existing from JSONB data
        existing_data = safe_get_changeset_data(assigns.changeset)

        case Multilang.get_raw_language_data(existing_data, current_lang) do
          %{^data_key => existing} -> Map.put(form_data, data_key, existing)
          _ -> form_data
        end
      end
    else
      form_data
    end
  end

  @doc """
  Merges language-specific validated data into the full multilang JSONB structure.

  Reads existing data from the changeset's `:data` field, then merges the new
  `validated_data` for the given `lang_code`.

  Handles three cases:
  - Multilang enabled: uses `Multilang.put_language_data/3`
  - Multilang disabled but data has multilang structure: preserves translations
  - Flat data, no multilang: passes through as-is

  The `changeset` must be an `Ecto.Changeset` with a `:data` field.
  `assigns` must contain `:multilang_enabled`.
  """
  def merge_multilang_data(changeset, lang_code, validated_data, assigns) do
    do_merge_multilang_data(changeset, lang_code, validated_data, assigns)
  end

  @doc """
  Gets the raw language data for the current language from a changeset.

  Use this in templates to read override-only values for secondary language tabs.
  Returns `%{}` when multilang is disabled.
  """
  def get_lang_data(changeset, current_lang, multilang_enabled) do
    if multilang_enabled && changeset do
      Multilang.get_raw_language_data(
        Ecto.Changeset.get_field(changeset, :data),
        current_lang
      )
    else
      %{}
    end
  end

  @doc """
  Returns true when on the primary language tab (or multilang is disabled).
  """
  def primary_tab?(assigns) do
    !assigns[:multilang_enabled] || assigns[:current_lang] == assigns[:primary_language]
  end

  @doc "Returns true when the Languages module is enabled with 2+ languages."
  def multilang_enabled? do
    Code.ensure_loaded?(Multilang) and Multilang.enabled?()
  rescue
    _ -> false
  end

  defp safe_primary_language do
    Multilang.primary_language()
  rescue
    _ -> "en-US"
  end

  defp safe_enabled_languages do
    Multilang.enabled_languages()
  rescue
    _ -> []
  end

  defp safe_build_language_tabs do
    Multilang.build_language_tabs()
  rescue
    _ -> []
  end

  # Safely reads a field from a changeset, returning "" on any error.
  defp safe_get_field(%Ecto.Changeset{} = changeset, field) when is_atom(field) do
    Ecto.Changeset.get_field(changeset, field) || ""
  rescue
    _ -> ""
  end

  defp safe_get_field(_changeset, _field), do: ""

  # Safely reads the :data field from a changeset, returning %{} on any error.
  defp safe_get_changeset_data(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.get_field(changeset, :data) || %{}
  rescue
    _ -> %{}
  end

  defp safe_get_changeset_data(_), do: %{}

  # ── Private helpers ────────────────────────────────────────────

  defp extract_translatable_data(params, fields, current_lang, primary) do
    Enum.reduce(fields, %{}, fn field, acc ->
      value =
        if current_lang == primary,
          do: params[field],
          else: params["lang_#{field}"]

      if is_binary(value), do: Map.put(acc, "_#{field}", value), else: acc
    end)
  end

  defp do_merge_multilang_data(changeset, lang_code, validated_data, assigns) do
    existing_data = safe_get_changeset_data(changeset)

    cond do
      assigns[:multilang_enabled] == true ->
        Multilang.put_language_data(existing_data, lang_code, validated_data)

      Multilang.multilang_data?(existing_data) ->
        Multilang.put_language_data(existing_data, lang_code, validated_data)

      true ->
        validated_data
    end
  end

  defp do_preserve_primary_fields(params, _changeset, assigns, preserve_fields)
       when map_size(preserve_fields) == 0 or
              not is_map_key(assigns, :multilang_enabled) do
    params
  end

  defp do_preserve_primary_fields(params, changeset, assigns, preserve_fields) do
    if assigns[:multilang_enabled] && assigns[:current_lang] != assigns[:primary_language] do
      Enum.reduce(preserve_fields, params, fn {str_key, atom_key}, acc ->
        preserve_field_value(acc, changeset, str_key, atom_key)
      end)
    else
      params
    end
  end

  defp preserve_field_value(params, changeset, str_key, atom_key) do
    if Map.has_key?(params, str_key) do
      params
    else
      case Ecto.Changeset.get_field(changeset, atom_key) do
        nil -> params
        value -> Map.put(params, str_key, value)
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Components
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Renders the language tab bar with compact/full mode.

  Shows a header with language icon, an info alert explaining the translation
  workflow, and the shared `<.language_switcher>` in `:tabs` variant with flags,
  names, and primary star indicator.

  Display mode:
  - `compact: nil` (default) — auto: full names when ≤ 5 languages, short codes when more
  - `compact: true` — always short codes
  - `compact: false` — always full names

  Delegates to `PhoenixKitWeb.Components.LanguageSwitcher.language_switcher/1`
  for the tab bar rendering.

  ## Attributes

    * `multilang_enabled` — boolean, whether multilang is active
    * `language_tabs` — list of tab maps from `Multilang.build_language_tabs/0`
    * `current_lang` — the currently selected language code
    * `compact` — force compact mode (short codes). Default: nil (auto)
    * `show_header` — show the "Content Language" header. Default: true
    * `show_info` — show the info alert. Default: true
  """
  attr :multilang_enabled, :boolean, required: true
  attr :language_tabs, :list, required: true
  attr :current_lang, :string, required: true
  attr :compact, :boolean, default: nil
  attr :show_header, :boolean, default: true
  attr :show_info, :boolean, default: true
  attr :class, :string, default: "card-body pb-0"

  def multilang_tabs(assigns) do
    display =
      cond do
        assigns.compact == true -> :compact
        assigns.compact == false -> :full
        true -> :auto
      end

    assigns = assign(assigns, :display, display)

    ~H"""
    <div :if={@multilang_enabled && length(@language_tabs) > 1} class={@class}>
      <div :if={@show_header} class="flex items-center justify-between mb-3">
        <div class="flex items-center gap-2">
          <.icon name="hero-language" class="w-5 h-5 text-primary" />
          <h2 class="card-title text-lg m-0">{gettext("Content Language")}</h2>
        </div>
        <% primary_tab = Enum.find(@language_tabs, fn t -> t.is_primary end) %>
        <div :if={primary_tab} class="flex items-center gap-1.5 text-xs text-base-content/60">
          <.icon name="hero-star-solid" class="w-3.5 h-3.5 text-primary" />
          <span>{gettext("Primary: %{lang}", lang: primary_tab.name)}</span>
        </div>
      </div>

      <div :if={@show_info} class="alert alert-info py-2 text-xs mb-4">
        <.icon name="hero-information-circle" class="w-4 h-4" />
        <span>
          {gettext(
            "Use the language tabs below to translate this record's content. The primary language (marked with a star) is required. Other languages are optional — any empty fields will fall back to the primary language value."
          )}
        </span>
      </div>

      <div class="mb-4">
        <.language_switcher
          languages={@language_tabs}
          current_language={@current_lang}
          on_click_js={&switch_lang_js(&1, @current_lang)}
          display={@display}
          auto_threshold={5}
          show_flags={true}
          show_primary={true}
          primary_divider={true}
          variant={:tabs}
          size={:sm}
        />
      </div>
    </div>
    """
  end

  @doc """
  Renders skeleton loading placeholders and a content wrapper for translatable fields.

  The skeleton is shown instantly on tab switch via JS, then hidden when LiveView
  re-renders with the new language data.

  Wrap your translatable form fields inside this component's inner block.

  ## Customizing skeletons

  Use the `:skeleton` slot to provide custom skeleton markup that matches
  your form layout. If omitted, a default two-field skeleton is rendered.

  ## Attributes

    * `multilang_enabled` — boolean
    * `current_lang` — current language code (used in element IDs for morphdom)
    * `skeleton_class` — CSS class for the skeleton container. Default: `"card-body pt-4"`
    * `fields_class` — CSS class for the fields container. Default: nil

  ## Example — default skeleton (card context)

      <.multilang_fields_wrapper multilang_enabled={@multilang_enabled} current_lang={@current_lang}>
        <%!-- translatable fields here --%>
      </.multilang_fields_wrapper>

  ## Example — custom skeleton and classes (non-card context)

      <.multilang_fields_wrapper
        multilang_enabled={@multilang_enabled}
        current_lang={@current_lang}
        skeleton_class="space-y-6"
        fields_class="space-y-6"
      >
        <:skeleton>
          <div class="grid grid-cols-2 gap-6">
            <div class="skeleton h-12 w-full"></div>
            <div class="skeleton h-12 w-full"></div>
          </div>
        </:skeleton>
        <%!-- translatable fields here --%>
      </.multilang_fields_wrapper>
  """
  attr :multilang_enabled, :boolean, required: true
  attr :current_lang, :string, required: true
  attr :skeleton_class, :string, default: "card-body pt-4"
  attr :fields_class, :string, default: nil
  slot :skeleton
  slot :inner_block, required: true

  def multilang_fields_wrapper(assigns) do
    ~H"""
    <%!-- Skeleton placeholders (shown instantly on tab click).
         IDs include current_lang so morphdom treats them as new elements. --%>
    <div
      :if={@multilang_enabled}
      id={"translatable-skeletons-#{@current_lang}"}
      data-translatable="skeletons"
      class={["hidden", @skeleton_class]}
      aria-busy="true"
      aria-label={gettext("Loading language content")}
    >
      <%= if @skeleton != [] do %>
        {render_slot(@skeleton)}
      <% else %>
        <div class="space-y-4">
          <div class="space-y-2">
            <div class="skeleton h-4 w-24"></div>
            <div class="skeleton h-12 w-full"></div>
          </div>
          <div class="space-y-2">
            <div class="skeleton h-4 w-32"></div>
            <div class="skeleton h-24 w-full"></div>
          </div>
        </div>
      <% end %>
    </div>

    <div
      id={if @multilang_enabled, do: "translatable-fields-#{@current_lang}", else: "form-fields"}
      data-translatable="fields"
      class={@fields_class}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders a translatable text input or textarea field.

  On the primary language tab, renders a standard input reading from the changeset.
  On secondary language tabs, renders with a language-specific name and uses the
  primary language value as placeholder text.

  Works both inside a `<.multilang_fields_wrapper>` (whole-form translation) and
  standalone (single-field translation).

  ## Translation models

  Supports two naming patterns for secondary language inputs:

  **Default (JSONB data column)** — used by entity data records:
  - Secondary name: `form_prefix[lang_field_name]`
  - Lang data key: `"_field_name"`

  **Settings translations** — used by entity definitions and other models
  that store translations in a `settings["translations"]` map. Set
  `secondary_name` and `lang_data_key` to override the defaults:

      <.translatable_field
        field_name="display_name"
        form_prefix="entities"
        secondary_name={"entities[translations][\#{@current_lang}][display_name]"}
        lang_data_key="display_name"
        ...
      />

  ## Attributes

    * `field_name` — the DB column name (e.g., "name")
    * `form_prefix` — the form name prefix (e.g., "catalogue")
    * `changeset` — the Ecto changeset
    * `schema_field` — the schema field atom (e.g., `:name`)
    * `multilang_enabled` — boolean
    * `current_lang` — current language code
    * `primary_language` — primary language code
    * `lang_data` — raw language data map for the current language
    * `label` — field label text
    * `placeholder` — placeholder for primary language (optional)
    * `type` — "input" or "textarea". Default: "input"
    * `rows` — textarea rows (only for type="textarea"). Default: 3
    * `required` — marks the primary language field as required. Default: false
    * `disabled` — disables the field. Default: false
    * `class` — additional CSS class(es) for the input element. Default: nil
    * `pattern` — HTML pattern attribute for input validation. Default: nil
    * `title` — HTML title attribute (for pattern validation message). Default: nil
    * `hint` — hint text shown below the field. Default: nil
    * `secondary_hint` — hint text shown only on secondary language tabs. Default: nil
    * `secondary_name` — override the secondary tab input name. Default: `"form_prefix[lang_field_name]"`
    * `lang_data_key` — key to look up in `lang_data` for secondary value.
      Default: `"_field_name"`. Set to `"field_name"` for settings translations.
  """
  attr :field_name, :string, required: true
  attr :form_prefix, :string, required: true
  attr :changeset, :any, required: true
  attr :schema_field, :atom, required: true
  attr :multilang_enabled, :boolean, required: true
  attr :current_lang, :string, required: true
  attr :primary_language, :string, required: true
  attr :lang_data, :map, required: true
  attr :label, :string, required: true
  attr :placeholder, :string, default: nil
  attr :type, :string, default: "input"
  attr :rows, :integer, default: 3
  attr :required, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :class, :string, default: nil
  attr :pattern, :string, default: nil
  attr :title, :string, default: nil
  attr :hint, :string, default: nil
  attr :secondary_hint, :string, default: nil
  attr :secondary_name, :string, default: nil
  attr :lang_data_key, :string, default: nil
  slot :label_extra

  def translatable_field(assigns) do
    # Coerce lang_data to map if nil/invalid
    assigns =
      if is_map(assigns.lang_data), do: assigns, else: assign(assigns, :lang_data, %{})

    is_primary = !assigns.multilang_enabled || assigns.current_lang == assigns.primary_language

    # Resolve the lang_data lookup key: custom or default "_field_name"
    data_key = assigns.lang_data_key || "_#{assigns.field_name}"

    # Resolve the secondary input name: custom or default "prefix[lang_field]"
    sec_name =
      assigns.secondary_name || "#{assigns.form_prefix}[lang_#{assigns.field_name}]"

    # Extract changeset errors for this field (primary tab only)
    errors = field_errors(assigns.changeset, assigns.schema_field, is_primary)

    assigns =
      assigns
      |> assign(:is_primary, is_primary)
      |> assign(:errors, errors)
      |> assign_new(:primary_value, fn ->
        safe_get_field(assigns.changeset, assigns.schema_field)
      end)
      |> assign_new(:lang_value, fn ->
        Map.get(assigns.lang_data, data_key)
      end)
      |> assign(:secondary_input_name, sec_name)
      |> assign_new(:input_id, fn ->
        if is_primary do
          "#{assigns.form_prefix}_#{assigns.field_name}"
        else
          "#{assigns.form_prefix}_#{assigns.field_name}_#{assigns.current_lang}"
        end
      end)
      |> assign_new(:input_class, fn ->
        base =
          if assigns.type == "textarea",
            do: "textarea textarea-bordered",
            else: "input input-bordered"

        base = if assigns.class, do: "#{base} #{assigns.class}", else: base
        if errors != [], do: "#{base} input-error", else: base
      end)

    ~H"""
    <div class="form-control" phx-feedback-for={if @is_primary, do: "#{@form_prefix}[#{@field_name}]"}>
      <label for={@input_id} class="label">
        <span class="label-text font-semibold">
          {@label}
          <%= if @required && @is_primary do %>
            *
          <% end %>
        </span>
        {render_slot(@label_extra)}
      </label>
      <%= if @type == "textarea" do %>
        <%= if @is_primary do %>
          <textarea
            name={"#{@form_prefix}[#{@field_name}]"}
            id={@input_id}
            class={@input_class}
            rows={@rows}
            phx-debounce="300"
            required={@required}
            disabled={@disabled}
          >{@primary_value}</textarea>
        <% else %>
          <textarea
            name={@secondary_input_name}
            id={@input_id}
            class={@input_class}
            rows={@rows}
            placeholder={@primary_value}
            phx-debounce="300"
            disabled={@disabled}
          >{@lang_value || ""}</textarea>
        <% end %>
      <% else %>
        <%= if @is_primary do %>
          <input
            type="text"
            name={"#{@form_prefix}[#{@field_name}]"}
            id={@input_id}
            value={@primary_value}
            class={@input_class}
            placeholder={@placeholder}
            phx-debounce="300"
            required={@required}
            disabled={@disabled}
            pattern={@pattern}
            title={@title}
          />
        <% else %>
          <input
            type="text"
            name={@secondary_input_name}
            id={@input_id}
            value={@lang_value}
            placeholder={@primary_value}
            class={@input_class}
            phx-debounce="300"
            disabled={@disabled}
            pattern={@pattern}
            title={@title}
          />
        <% end %>
      <% end %>
      <.error :for={msg <- @errors}>{msg}</.error>
      <label :if={@hint && @is_primary && @errors == []} class="label">
        <span class="label-text-alt">{@hint}</span>
      </label>
      <label :if={@secondary_hint && !@is_primary} class="label">
        <span class="label-text-alt">{@secondary_hint}</span>
      </label>
    </div>
    """
  end

  # Extracts translated error messages for a field from the changeset.
  # Only returns errors on the primary tab — secondary tabs don't validate DB columns.
  defp field_errors(%Ecto.Changeset{action: action, errors: errors}, field, true = _is_primary)
       when not is_nil(action) do
    errors
    |> Keyword.get_values(field)
    |> Enum.map(&translate_error/1)
  end

  defp field_errors(_changeset, _field, _is_primary), do: []

  # ── JS helper ──────────────────────────────────────────────────

  @doc """
  Returns a `Phoenix.LiveView.JS` command that switches languages.

  Pushes the `"switch_language"` event, hides current field content,
  and shows skeleton placeholders for instant visual feedback.

  Returns a no-op when `lang_code == current_lang` to prevent skeleton ghosts.
  """
  def switch_lang_js(lang_code, current_lang) do
    if lang_code == current_lang do
      %JS{}
    else
      JS.push("switch_language", value: %{lang: lang_code})
      |> JS.add_class("hidden", to: "[data-translatable=fields]")
      |> JS.remove_class("hidden", to: "[data-translatable=skeletons]")
    end
  end
end
