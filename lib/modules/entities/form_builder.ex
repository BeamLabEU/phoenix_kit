defmodule PhoenixKit.Modules.Entities.FormBuilder do
  @moduledoc """
  Dynamic form builder for entity data forms.

  This module generates Phoenix.Component forms based on entity field definitions,
  enabling dynamic data entry forms that adapt to the entity's schema.

  ## Usage

      # Generate form fields for an entity
      fields_html = PhoenixKit.Modules.Entities.FormBuilder.build_fields(entity, changeset)

      # Generate a single field
      field_html = PhoenixKit.Modules.Entities.FormBuilder.build_field(field_definition, changeset)

      # Validate entity data against field definitions
      {:ok, validated_data} = PhoenixKit.Modules.Entities.FormBuilder.validate_data(entity, data_params)

  ## Field Type Support

  The FormBuilder supports all field types defined in `PhoenixKit.Modules.Entities.FieldTypes`:

  - **Basic Types**: text, textarea, email, url, rich_text
  - **Numeric Types**: number
  - **Boolean Types**: boolean (toggle/checkbox)
  - **Date Types**: date
  - **Choice Types**: select, radio, checkbox (with options)
  - **Media Types**: image, file (upload)
  - **Relational Types**: relation (entity references)

  ## Form Generation

  Forms are generated as Phoenix.Component HTML with proper validation,
  error handling, and styling consistent with the PhoenixKit design system.
  """

  import Phoenix.Component
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.FormFieldLabel, only: [label: 1]
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Entities.Multilang

  @doc """
  Builds form fields HTML for an entire entity.

  Takes an entity with its field definitions and generates the complete
  form HTML for data entry.

  ## Parameters

  - `entity` - The entity struct with fields_definition
  - `changeset` - The changeset for the entity data
  - `opts` - Optional configuration (default: [])

  ## Options

  - `:wrapper_class` - CSS class for field wrapper divs
  - `:input_class` - CSS class for input elements
  - `:label_class` - CSS class for label elements

  ## Examples

      iex> entity = %Entities{fields_definition: [
      ...>   %{"type" => "text", "key" => "title", "label" => "Title", "required" => true}
      ...> ]}
      iex> changeset = Ecto.Changeset.cast(%{}, %{}, [])
      iex> PhoenixKit.Modules.Entities.FormBuilder.build_fields(entity, changeset)
      # Returns Phoenix.Component form HTML
  """
  def build_fields(entity, changeset, opts \\ []) do
    fields_definition = entity.fields_definition || []
    lang_code = opts[:lang_code]

    # For secondary languages, extract primary data for placeholder text
    opts = maybe_add_primary_placeholders(opts, changeset, entity, lang_code)

    # When multilang: extract language-specific data into a view changeset
    # so all existing build_field/get_field_value calls work unchanged.
    changeset = maybe_apply_language_view(changeset, entity, lang_code)

    assigns = %{
      fields_definition: fields_definition,
      changeset: changeset,
      opts: opts
    }

    ~H"""
    <div class="space-y-6">
      <%= for field <- @fields_definition do %>
        <div class={["form-field-wrapper", @opts[:wrapper_class]]}>
          {build_field(field, @changeset, @opts)}
        </div>
      <% end %>
    </div>
    """
  end

  # When a lang_code is provided, extract that language's data (merged with
  # primary) and replace the :data field in the changeset so downstream
  # build_field calls read the correct values via get_field_value/2.
  defp maybe_apply_language_view(changeset, _entity, nil), do: changeset

  defp maybe_apply_language_view(%Phoenix.HTML.Form{} = form, _entity, lang_code) do
    data = Ecto.Changeset.get_field(form.source, :data)

    if Multilang.multilang_data?(data) do
      lang_data = Multilang.get_language_data(data, lang_code)
      updated_changeset = Ecto.Changeset.put_change(form.source, :data, lang_data)
      %{form | source: updated_changeset}
    else
      form
    end
  end

  defp maybe_apply_language_view(changeset, _entity, lang_code) do
    data = Ecto.Changeset.get_field(changeset, :data)

    if Multilang.multilang_data?(data) do
      lang_data = Multilang.get_language_data(data, lang_code)
      Ecto.Changeset.put_change(changeset, :data, lang_data)
    else
      changeset
    end
  end

  # ── Multilang placeholder helpers ──────────────────────────────

  defp maybe_add_primary_placeholders(opts, _changeset, _entity, nil), do: opts

  defp maybe_add_primary_placeholders(opts, changeset, _entity, lang_code) do
    primary = Multilang.primary_language()

    if lang_code == primary do
      opts
    else
      data = extract_data_from_changeset(changeset)

      if Multilang.multilang_data?(data) do
        primary_data = Multilang.get_primary_data(data)
        Keyword.put(opts, :primary_placeholders, primary_data)
      else
        opts
      end
    end
  end

  defp extract_data_from_changeset(%Phoenix.HTML.Form{} = form),
    do: Ecto.Changeset.get_field(form.source, :data)

  defp extract_data_from_changeset(changeset),
    do: Ecto.Changeset.get_field(changeset, :data)

  defp get_effective_placeholder(field, opts, default \\ "") do
    case opts[:primary_placeholders] do
      %{} = primary_data ->
        primary_value = Map.get(primary_data, field["key"])

        if primary_value != nil and to_string(primary_value) != "" do
          to_string(primary_value)
        else
          field["placeholder"] || default
        end

      _ ->
        field["placeholder"] || default
    end
  end

  # For text-like fields on secondary languages, show empty when value
  # matches primary (inherited) — the primary value appears as placeholder.
  defp get_effective_text_value(changeset, field_key, opts) do
    current = get_field_value(changeset, field_key)

    case opts[:primary_placeholders] do
      %{} = primary_data ->
        primary_value = Map.get(primary_data, field_key)
        if inherited_value?(current, primary_value), do: nil, else: current

      _ ->
        current
    end
  end

  defp inherited_value?(nil, _), do: true
  defp inherited_value?("", _), do: true
  defp inherited_value?(a, b), do: to_string(a) == to_string(b)

  @doc """
  Builds a single form field based on field definition.

  ## Parameters

  - `field` - Field definition map
  - `changeset` - The changeset for validation and values
  - `opts` - Optional configuration

  ## Examples

      iex> field = %{"type" => "text", "key" => "title", "label" => "Title"}
      iex> changeset = Ecto.Changeset.cast(%{}, %{}, [])
      iex> PhoenixKit.Modules.Entities.FormBuilder.build_field(field, changeset)
      # Returns Phoenix.Component field HTML
  """
  def build_field(field, changeset, opts \\ [])

  # Text Input
  def build_field(%{"type" => "text"} = field, changeset, opts) do
    placeholder = get_effective_placeholder(field, opts)
    value = get_effective_text_value(changeset, field["key"], opts)

    assigns = %{
      field: field,
      changeset: changeset,
      opts: opts,
      placeholder: placeholder,
      value: value
    }

    ~H"""
    <div>
      <.label>
        {@field["label"]}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <input
        type="text"
        name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
        value={@value}
        placeholder={@placeholder}
        class={["input input-bordered w-full", @opts[:input_class]]}
        maxlength={@field["max_length"]}
        required={@field["required"] && !@opts[:primary_placeholders]}
        disabled={@opts[:disabled]}
      />
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="label-text-alt">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Textarea
  def build_field(%{"type" => "textarea"} = field, changeset, opts) do
    placeholder = get_effective_placeholder(field, opts)
    value = get_effective_text_value(changeset, field["key"], opts)

    assigns = %{
      field: field,
      changeset: changeset,
      opts: opts,
      placeholder: placeholder,
      value: value
    }

    ~H"""
    <div>
      <.label for={@field["key"]}>
        {@field["label"]}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <textarea
        name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
        placeholder={@placeholder}
        class={["textarea textarea-bordered w-full", @opts[:input_class]]}
        rows={@field["rows"] || 4}
        maxlength={@field["max_length"]}
        required={@field["required"] && !@opts[:primary_placeholders]}
        disabled={@opts[:disabled]}
      >{@value}</textarea>
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="label-text-alt">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Email Input
  def build_field(%{"type" => "email"} = field, changeset, opts) do
    placeholder = get_effective_placeholder(field, opts, gettext("user@example.com"))
    value = get_effective_text_value(changeset, field["key"], opts)

    assigns = %{
      field: field,
      changeset: changeset,
      opts: opts,
      placeholder: placeholder,
      value: value
    }

    ~H"""
    <div>
      <.label for={@field["key"]}>
        {@field["label"]}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <input
        type="email"
        name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
        value={@value}
        placeholder={@placeholder}
        class={["input input-bordered w-full", @opts[:input_class]]}
        required={@field["required"] && !@opts[:primary_placeholders]}
        disabled={@opts[:disabled]}
      />
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="label-text-alt">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # URL Input
  def build_field(%{"type" => "url"} = field, changeset, opts) do
    placeholder = get_effective_placeholder(field, opts, gettext("https://example.com"))
    value = get_effective_text_value(changeset, field["key"], opts)

    assigns = %{
      field: field,
      changeset: changeset,
      opts: opts,
      placeholder: placeholder,
      value: value
    }

    ~H"""
    <div>
      <.label for={@field["key"]}>
        {@field["label"]}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <input
        type="url"
        name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
        value={@value}
        placeholder={@placeholder}
        class={["input input-bordered w-full", @opts[:input_class]]}
        required={@field["required"] && !@opts[:primary_placeholders]}
        disabled={@opts[:disabled]}
      />
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="label-text-alt">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Rich Text Editor
  def build_field(%{"type" => "rich_text"} = field, changeset, opts) do
    placeholder = get_effective_placeholder(field, opts, gettext("Enter rich text content..."))
    value = get_effective_text_value(changeset, field["key"], opts)

    assigns = %{
      field: field,
      changeset: changeset,
      opts: opts,
      placeholder: placeholder,
      value: value
    }

    ~H"""
    <div>
      <.label for={@field["key"]}>
        {@field["label"]}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <textarea
        name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
        placeholder={@placeholder}
        class={["textarea textarea-bordered w-full h-32", @opts[:input_class]]}
        rows="8"
        required={@field["required"] && !@opts[:primary_placeholders]}
        disabled={@opts[:disabled]}
      >{@value}</textarea>
      <.label class="label">
        <span class="label-text-alt">{gettext("Rich text editor (HTML supported)")}</span>
      </.label>
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="label-text-alt">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Number Input
  def build_field(%{"type" => "number"} = field, changeset, opts) do
    placeholder = get_effective_placeholder(field, opts)
    value = get_effective_text_value(changeset, field["key"], opts)

    assigns = %{
      field: field,
      changeset: changeset,
      opts: opts,
      placeholder: placeholder,
      value: value
    }

    ~H"""
    <div>
      <.label for={@field["key"]}>
        {@field["label"]}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <input
        type="number"
        name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
        value={@value}
        placeholder={@placeholder}
        class={["input input-bordered w-full", @opts[:input_class]]}
        min={@field["min"]}
        max={@field["max"]}
        step={@field["step"] || 1}
        required={@field["required"] && !@opts[:primary_placeholders]}
        disabled={@opts[:disabled]}
      />
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="label-text-alt">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Boolean Toggle
  def build_field(%{"type" => "boolean"} = field, changeset, opts) do
    field_value = get_field_value(changeset, field["key"])
    is_checked = field_value in [true, "true", "1", 1]

    assigns = %{field: field, changeset: changeset, opts: opts, is_checked: is_checked}

    ~H"""
    <div>
      <.label>
        {@field["label"]}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <div class="form-control">
        <label class="label cursor-pointer justify-start gap-4">
          <input
            type="hidden"
            name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
            value="false"
          />
          <input
            type="checkbox"
            name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
            value="true"
            checked={@is_checked}
            class={["toggle toggle-primary", @opts[:input_class]]}
            disabled={@opts[:disabled]}
          />
          <span class="label-text">
            {if @is_checked, do: gettext("Enabled"), else: gettext("Disabled")}
          </span>
        </label>
      </div>
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="label-text-alt">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Date Input
  def build_field(%{"type" => "date"} = field, changeset, opts) do
    assigns = %{field: field, changeset: changeset, opts: opts}

    ~H"""
    <div>
      <.label for={@field["key"]}>
        {@field["label"]}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <input
        type="date"
        name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
        value={get_field_value(@changeset, @field["key"])}
        class={["input input-bordered w-full", @opts[:input_class]]}
        required={@field["required"]}
        disabled={@opts[:disabled]}
      />
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="label-text-alt">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Select Dropdown
  def build_field(%{"type" => "select"} = field, changeset, opts) do
    assigns = %{field: field, changeset: changeset, opts: opts}

    ~H"""
    <div>
      <.label for={@field["key"]}>
        {@field["label"]}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <select
        name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
        class={["select select-bordered w-full", @opts[:input_class]]}
        required={@field["required"]}
        disabled={@opts[:disabled]}
      >
        <%= if @field["allow_empty"] || !@field["required"] do %>
          <option value="">{@field["placeholder"] || gettext("Select an option...")}</option>
        <% end %>
        <%= for option <- (@field["options"] || []) do %>
          <option
            value={option}
            selected={get_field_value(@changeset, @field["key"]) == option}
          >
            {option}
          </option>
        <% end %>
      </select>
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="label-text-alt">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Radio Buttons
  def build_field(%{"type" => "radio"} = field, changeset, opts) do
    assigns = %{field: field, changeset: changeset, opts: opts}

    ~H"""
    <div>
      <.label>
        {@field["label"]}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <div class="flex flex-col gap-2">
        <%= for {option, index} <- Enum.with_index(@field["options"] || []) do %>
          <label class="flex items-center cursor-pointer">
            <input
              type="radio"
              name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}]"}
              value={option}
              class={["radio radio-primary mr-2", @opts[:input_class]]}
              checked={get_field_value(@changeset, @field["key"]) == option}
              required={@field["required"]}
              disabled={@opts[:disabled]}
            />
            <span class="label-text">{option}</span>
          </label>
        <% end %>
      </div>
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="label-text-alt">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Checkbox Group
  def build_field(%{"type" => "checkbox"} = field, changeset, opts) do
    assigns = %{field: field, changeset: changeset, opts: opts}

    ~H"""
    <div>
      <.label>
        {@field["label"]}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <div class="flex flex-col gap-2">
        <%= for {option, index} <- Enum.with_index(@field["options"] || []) do %>
          <label class="flex items-center cursor-pointer">
            <input
              type="checkbox"
              name={"#{@changeset.data.__struct__.__schema__(:source)}[data][#{@field["key"]}][]"}
              value={option}
              class={["checkbox checkbox-primary mr-2", @opts[:input_class]]}
              checked={option in (get_field_value(@changeset, @field["key"]) || [])}
              disabled={@opts[:disabled]}
            />
            <span class="label-text">{option}</span>
          </label>
        <% end %>
      </div>
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="label-text-alt">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Image Upload (placeholder - not yet implemented)
  def build_field(%{"type" => "image"} = field, changeset, opts) do
    assigns = %{field: field, changeset: changeset, opts: opts}

    ~H"""
    <div>
      <.label>
        {@field["label"]}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <div class="border-2 border-dashed border-base-300 rounded-lg p-6 text-center bg-base-200/50">
        <.icon name="hero-photo" class="w-12 h-12 mx-auto text-base-content/40 mb-3" />
        <p class="text-base-content/60 text-sm mb-2">
          {gettext("Image upload coming soon")}
        </p>
        <p class="text-base-content/40 text-xs">
          {gettext("This feature is not yet available")}
        </p>
      </div>
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="label-text-alt">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # File Upload (admin entity forms - requires LiveView upload configuration)
  def build_field(%{"type" => "file"} = field, changeset, opts) do
    # Get current value from changeset (array of file metadata)
    current_files = get_field_value(changeset, field["key"]) || []

    # Extract upload configuration
    max_entries = field["max_entries"] || 5
    max_file_size_mb = Float.round((field["max_file_size"] || 15_728_640) / 1_048_576, 1)
    accept_list = field["accept"] || [".pdf", ".jpg", ".jpeg", ".png"]

    accept_display =
      Enum.map_join(accept_list, ", ", fn ext ->
        ext |> String.replace_prefix(".", "") |> String.upcase()
      end)

    assigns = %{
      field: field,
      changeset: changeset,
      opts: opts,
      current_files: current_files,
      max_entries: max_entries,
      max_file_size_mb: max_file_size_mb,
      accept_display: accept_display
    }

    ~H"""
    <div>
      <.label>
        {@field["label"]}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>

      <%!-- Display current files if any --%>
      <%= if @current_files != [] and is_list(@current_files) do %>
        <div class="mb-3 space-y-2">
          <p class="text-sm font-semibold text-base-content/70">
            {gettext("Current files:")}
          </p>
          <%= for file <- @current_files do %>
            <div class="flex items-center gap-2 p-2 bg-base-200 rounded text-sm">
              <.icon name="hero-document" class="w-4 h-4 text-base-content/60" />
              <span class="flex-1 truncate">{file["filename"] || gettext("Unknown file")}</span>
              <%= if file["size"] do %>
                <span class="text-xs text-base-content/60">
                  {format_bytes(file["size"])}
                </span>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>

      <%!-- File upload placeholder for admin forms --%>
      <div class="border-2 border-dashed border-base-300 rounded-lg p-6 text-center bg-base-200/50">
        <.icon name="hero-document-arrow-up" class="w-12 h-12 mx-auto text-base-content/40 mb-3" />
        <p class="text-base-content/60 text-sm mb-2">
          {gettext("File upload in admin forms requires LiveView upload configuration")}
        </p>
        <p class="text-base-content/40 text-xs mb-3">
          {gettext("File uploads work in public forms (contact forms, etc.)")}
        </p>

        <%!-- Show field configuration --%>
        <div class="text-left mt-4 p-3 bg-base-100 rounded text-xs space-y-1">
          <p class="font-semibold text-base-content/70">{gettext("Field Configuration:")}</p>
          <p class="text-base-content/60">
            • {gettext("Accepted types:")} {@accept_display}
          </p>
          <p class="text-base-content/60">
            • {gettext("Max files:")} {@max_entries}
          </p>
          <p class="text-base-content/60">
            • {gettext("Max size:")} {@max_file_size_mb} MB {gettext("per file")}
          </p>
        </div>
      </div>

      <%= if @field["description"] do %>
        <.label class="label">
          <span class="label-text-alt">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Relation Field (placeholder - not yet implemented)
  def build_field(%{"type" => "relation"} = field, changeset, opts) do
    assigns = %{field: field, changeset: changeset, opts: opts}

    ~H"""
    <div>
      <.label>
        {@field["label"]}{if @field["required"] && !@opts[:primary_placeholders], do: " *"}
      </.label>
      <div class="border-2 border-dashed border-base-300 rounded-lg p-6 text-center bg-base-200/50">
        <.icon name="hero-link" class="w-12 h-12 mx-auto text-base-content/40 mb-3" />
        <p class="text-base-content/60 text-sm mb-2">
          {gettext("Entity relations coming soon")}
        </p>
        <p class="text-base-content/40 text-xs">
          {gettext("This feature is not yet available")}
        </p>
      </div>
      <%= if @field["description"] do %>
        <.label class="label">
          <span class="label-text-alt">{@field["description"]}</span>
        </.label>
      <% end %>
    </div>
    """
  end

  # Fallback for unknown field types
  def build_field(field, changeset, opts) do
    assigns = %{field: field, changeset: changeset, opts: opts}

    ~H"""
    <div class="alert alert-warning">
      <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
      <span>{gettext("Unknown field type: %{type}", type: @field["type"])}</span>
    </div>
    """
  end

  # Helper function to format file sizes
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"

  defp format_bytes(bytes) when bytes < 1_048_576 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_bytes(bytes) do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  @doc """
  Validates entity data against field definitions.

  Takes entity field definitions and validates submitted data parameters
  according to the field types, requirements, and constraints.

  ## Parameters

  - `entity` - The entity with field definitions
  - `data_params` - Map of submitted data parameters

  ## Returns

  - `{:ok, validated_data}` - Successfully validated data
  - `{:error, errors}` - Validation errors

  ## Examples

      iex> entity = %Entities{fields_definition: [
      ...>   %{"type" => "text", "key" => "title", "required" => true}
      ...> ]}
      iex> PhoenixKit.Modules.Entities.FormBuilder.validate_data(entity, %{"title" => "Test"})
      {:ok, %{"title" => "Test"}}

      iex> PhoenixKit.Modules.Entities.FormBuilder.validate_data(entity, %{})
      {:error, %{"title" => ["is required"]}}
  """
  def validate_data(entity, data_params, lang_code \\ nil)

  def validate_data(entity, data_params, nil) do
    fields_definition = entity.fields_definition || []
    errors = %{}
    validated_data = %{}

    result =
      Enum.reduce(fields_definition, {validated_data, errors}, fn field, {data_acc, errors_acc} ->
        field_key = field["key"]
        field_value = Map.get(data_params, field_key)

        case validate_field_value(field, field_value) do
          {:ok, validated_value} ->
            {Map.put(data_acc, field_key, validated_value), errors_acc}

          {:error, field_errors} ->
            {data_acc, Map.put(errors_acc, field_key, field_errors)}
        end
      end)

    case result do
      {validated_data, errors} when map_size(errors) == 0 ->
        {:ok, validated_data}

      {_data, errors} ->
        {:error, errors}
    end
  end

  def validate_data(entity, data_params, lang_code) do
    primary = Multilang.primary_language()

    if lang_code == primary do
      # Primary language: full validation (same as default)
      validate_data(entity, data_params, nil)
    else
      # Secondary language: type validation only, no required checks.
      # Empty values are stripped (not stored as overrides).
      validate_secondary_data(entity, data_params)
    end
  end

  defp validate_secondary_data(entity, data_params) do
    fields_definition = entity.fields_definition || []

    result =
      Enum.reduce(fields_definition, {%{}, %{}}, fn field, {data_acc, errors_acc} ->
        field_key = field["key"]
        field_value = Map.get(data_params, field_key)

        case field_value do
          nil ->
            {data_acc, errors_acc}

          "" ->
            {data_acc, errors_acc}

          value ->
            case validate_type(field, value) do
              {:ok, validated_value} ->
                {Map.put(data_acc, field_key, validated_value), errors_acc}

              {:error, field_errors} ->
                {data_acc, Map.put(errors_acc, field_key, field_errors)}
            end
        end
      end)

    case result do
      {validated_data, errors} when map_size(errors) == 0 ->
        {:ok, validated_data}

      {_data, errors} ->
        {:error, errors}
    end
  end

  @doc """
  Gets the current value of a field from a changeset.

  Helper function to extract field values from changesets or forms for form rendering.
  """
  def get_field_value(%Phoenix.HTML.Form{} = form, field_key) do
    # When passed a form, access the underlying changeset
    # Use Ecto.Changeset.get_field to get the value from changes or fallback to struct
    case Ecto.Changeset.get_field(form.source, :data) do
      nil -> nil
      data when is_map(data) -> Map.get(data, field_key)
      _ -> nil
    end
  end

  def get_field_value(changeset, field_key) do
    # When passed a changeset directly
    case Ecto.Changeset.get_field(changeset, :data) do
      nil -> nil
      data when is_map(data) -> Map.get(data, field_key)
      _ -> nil
    end
  end

  # Private Functions

  defp validate_field_value(field, value) do
    with {:ok, value} <- validate_required(field, value) do
      validate_type(field, value)
    end
  end

  defp validate_required(%{"required" => true}, value) when value in [nil, ""] do
    {:error, [gettext("is required")]}
  end

  defp validate_required(_field, value), do: {:ok, value}

  defp validate_type(%{"type" => "email"}, value) when is_binary(value) and value != "" do
    if String.contains?(value, "@") do
      {:ok, value}
    else
      {:error, [gettext("must be a valid email address")]}
    end
  end

  defp validate_type(%{"type" => "url"}, value) when is_binary(value) and value != "" do
    normalized_value =
      if String.starts_with?(value, ["http://", "https://"]) do
        value
      else
        "https://#{value}"
      end

    {:ok, normalized_value}
  end

  defp validate_type(%{"type" => "number"}, value) when is_binary(value) and value != "" do
    case Float.parse(value) do
      {num, ""} -> {:ok, num}
      _ -> {:error, [gettext("must be a valid number")]}
    end
  end

  defp validate_type(%{"type" => "boolean"}, value) do
    cond do
      value in [true, "true", "1", 1] -> {:ok, true}
      value in [false, "false", "0", 0, nil, ""] -> {:ok, false}
      true -> {:error, [gettext("must be true or false")]}
    end
  end

  defp validate_type(%{"type" => "select", "options" => options}, value) when is_list(options) do
    cond do
      value in [nil, ""] -> {:ok, nil}
      value in options -> {:ok, value}
      true -> {:error, [gettext("must be one of: %{options}", options: Enum.join(options, ", "))]}
    end
  end

  defp validate_type(%{"type" => "radio", "options" => options}, value) when is_list(options) do
    cond do
      value in [nil, ""] -> {:ok, nil}
      value in options -> {:ok, value}
      true -> {:error, [gettext("must be one of: %{options}", options: Enum.join(options, ", "))]}
    end
  end

  defp validate_type(%{"type" => "checkbox", "options" => options}, values)
       when is_list(options) and is_list(values) do
    invalid_values = values -- options

    if Enum.empty?(invalid_values) do
      {:ok, values}
    else
      {:error,
       [gettext("contains invalid options: %{invalid}", invalid: Enum.join(invalid_values, ", "))]}
    end
  end

  defp validate_type(_field, value), do: {:ok, value}
end
