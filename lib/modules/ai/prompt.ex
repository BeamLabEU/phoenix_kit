defmodule PhoenixKit.Modules.AI.Prompt do
  @moduledoc """
  AI prompt schema for PhoenixKit AI system.

  A prompt is a reusable text template with variable substitution support.
  Variables use the `{{VariableName}}` syntax and are automatically extracted
  from the content when saved.

  ## Schema Fields

  ### Identity
  - `name`: Display name for the prompt (unique)
  - `slug`: URL-friendly identifier (auto-generated from name, unique)
  - `description`: Optional description of the prompt's purpose

  ### Content
  - `content`: The prompt template text with optional `{{variables}}`
  - `variables`: Auto-extracted variable names from content

  ### Status
  - `enabled`: Whether the prompt is active
  - `sort_order`: Display order for listing

  ### Usage Tracking
  - `usage_count`: Number of times the prompt has been used
  - `last_used_at`: Timestamp of the last usage

  ### Metadata
  - `metadata`: Flexible JSON storage for additional data

  ## Variable Syntax

  Variables use double curly braces: `{{VariableName}}`

  - Variable names must be alphanumeric with underscores
  - Variables are case-sensitive
  - Unmatched variables remain in the output as-is

  ## Usage Examples

      # Create a prompt
      {:ok, prompt} = PhoenixKit.Modules.AI.create_prompt(%{
        name: "Translator",
        content: "Translate the following text to {{Language}}:\\n\\n{{Text}}"
      })
      # Variables auto-extracted: ["Language", "Text"]

      # Render with variables
      {:ok, text} = PhoenixKit.Modules.AI.Prompt.render(prompt, %{
        "Language" => "French",
        "Text" => "Hello, world!"
      })
      # => "Translate the following text to French:\\n\\nHello, world!"

      # Use with AI completion
      {:ok, response} = PhoenixKit.Modules.AI.ask_with_prompt(
        endpoint_id,
        prompt.id,
        %{"Language" => "Spanish", "Text" => "Good morning"}
      )
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Utils.Slug

  # Use UUID as the primary key in Ecto, mapped to the 'uuid' column in DB
  # The DB still has integer 'id' as the actual PK, kept as legacy_id for FK compatibility
  @primary_key {:id, Ecto.UUID, autogenerate: true, source: :uuid}

  # Regex for extracting variable names from content
  @variable_regex ~r/\{\{(\w+)\}\}/

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :slug,
             :description,
             :content,
             :variables,
             :enabled,
             :sort_order,
             :usage_count,
             :last_used_at,
             :metadata,
             :inserted_at,
             :updated_at
           ]}

  schema "phoenix_kit_ai_prompts" do
    # Old integer ID kept for foreign key compatibility
    field :legacy_id, :integer, source: :id, read_after_writes: true

    # Identity
    field :name, :string
    field :slug, :string
    field :description, :string

    # Content
    field :content, :string
    field :variables, {:array, :string}, default: []

    # Status
    field :enabled, :boolean, default: true
    field :sort_order, :integer, default: 0

    # Usage tracking
    field :usage_count, :integer, default: 0
    field :last_used_at, :utc_datetime_usec

    # Flexible metadata
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for prompt creation and updates.
  """
  def changeset(prompt, attrs) do
    prompt
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :content,
      :variables,
      :enabled,
      :sort_order,
      :usage_count,
      :last_used_at,
      :metadata
    ])
    |> validate_required([:name, :content])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 500)
    |> unique_constraint(:name, name: :phoenix_kit_ai_prompts_name_uidx)
    |> unique_constraint(:slug, name: :phoenix_kit_ai_prompts_slug_uidx)
    |> maybe_generate_slug()
    |> auto_extract_variables()
  end

  @doc """
  Creates a changeset for incrementing usage.
  """
  def usage_changeset(prompt) do
    change(prompt,
      usage_count: (prompt.usage_count || 0) + 1,
      last_used_at: DateTime.utc_now()
    )
  end

  @doc """
  Extracts variable names from content.

  Variables are matched using the `{{VariableName}}` syntax.
  Returns a list of unique variable names in order of appearance.

  ## Examples

      iex> PhoenixKit.Modules.AI.Prompt.extract_variables("Hello {{Name}}, welcome to {{Place}}!")
      ["Name", "Place"]

      iex> PhoenixKit.Modules.AI.Prompt.extract_variables("No variables here")
      []

      iex> PhoenixKit.Modules.AI.Prompt.extract_variables("{{A}} and {{B}} and {{A}} again")
      ["A", "B"]
  """
  def extract_variables(content) when is_binary(content) do
    @variable_regex
    |> Regex.scan(content)
    |> Enum.map(fn [_full, name] -> name end)
    |> Enum.uniq()
  end

  def extract_variables(_), do: []

  @doc """
  Renders a prompt by replacing variables with provided values.

  Variables not found in the values map remain as-is in the output.
  Supports both string and atom keys in the values map.

  ## Examples

      iex> prompt = %PhoenixKit.Modules.AI.Prompt{content: "Hello {{Name}}!"}
      iex> PhoenixKit.Modules.AI.Prompt.render(prompt, %{"Name" => "World"})
      {:ok, "Hello World!"}

      iex> prompt = %PhoenixKit.Modules.AI.Prompt{content: "Translate to {{Lang}}: {{Text}}"}
      iex> PhoenixKit.Modules.AI.Prompt.render(prompt, %{Lang: "French", Text: "Hello"})
      {:ok, "Translate to French: Hello"}

      iex> prompt = %PhoenixKit.Modules.AI.Prompt{content: "Missing {{Var}}"}
      iex> PhoenixKit.Modules.AI.Prompt.render(prompt, %{})
      {:ok, "Missing {{Var}}"}
  """
  def render(%__MODULE__{content: content}, variables) when is_map(variables) do
    result =
      Regex.replace(@variable_regex, content, fn full_match, var_name ->
        get_variable_value(variables, var_name, full_match)
      end)

    {:ok, result}
  end

  def render(%__MODULE__{content: content}, _variables) do
    {:ok, content}
  end

  @doc """
  Renders content string directly (without a Prompt struct).

  Useful for previewing variable substitution.

  ## Examples

      iex> PhoenixKit.Modules.AI.Prompt.render_content("Hello {{Name}}!", %{"Name" => "World"})
      {:ok, "Hello World!"}
  """
  def render_content(content, variables) when is_binary(content) and is_map(variables) do
    result =
      Regex.replace(@variable_regex, content, fn full_match, var_name ->
        get_variable_value(variables, var_name, full_match)
      end)

    {:ok, result}
  end

  def render_content(content, _) when is_binary(content), do: {:ok, content}

  @doc """
  Validates that all required variables are provided.

  Returns `:ok` if all variables are present, or `{:error, missing}` with
  a list of missing variable names.

  ## Examples

      iex> prompt = %PhoenixKit.Modules.AI.Prompt{variables: ["Name", "Age"]}
      iex> PhoenixKit.Modules.AI.Prompt.validate_variables(prompt, %{"Name" => "John", "Age" => "30"})
      :ok

      iex> prompt = %PhoenixKit.Modules.AI.Prompt{variables: ["Name", "Age"]}
      iex> PhoenixKit.Modules.AI.Prompt.validate_variables(prompt, %{"Name" => "John"})
      {:error, ["Age"]}
  """
  def validate_variables(%__MODULE__{variables: variables}, provided) when is_map(provided) do
    provided_keys =
      provided
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    missing =
      variables
      |> Enum.reject(fn var -> MapSet.member?(provided_keys, var) end)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, missing}
    end
  end

  def validate_variables(%__MODULE__{variables: []}, _), do: :ok
  def validate_variables(%__MODULE__{variables: vars}, _), do: {:error, vars}

  @doc """
  Returns a truncated preview of the content for display.
  """
  def content_preview(nil), do: ""
  def content_preview(""), do: ""

  def content_preview(content) when is_binary(content) do
    content
    |> String.slice(0, 100)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> maybe_add_ellipsis(String.length(content))
  end

  @doc """
  Generates a URL-friendly slug from the name.

  Uses `PhoenixKit.Utils.Slug.slugify/1` for consistent slug generation.

  ## Examples

      iex> PhoenixKit.Modules.AI.Prompt.generate_slug("My Cool Prompt!")
      "my-cool-prompt"

      iex> PhoenixKit.Modules.AI.Prompt.generate_slug("Translate to French")
      "translate-to-french"
  """
  def generate_slug(nil), do: ""
  def generate_slug(""), do: ""

  def generate_slug(name) when is_binary(name) do
    Slug.slugify(name)
  end

  @doc """
  Returns the variable regex pattern.
  """
  def variable_regex, do: @variable_regex

  @doc """
  Checks if a prompt has any variables defined.

  ## Examples

      iex> prompt = %PhoenixKit.Modules.AI.Prompt{variables: ["Name", "Age"]}
      iex> PhoenixKit.Modules.AI.Prompt.has_variables?(prompt)
      true

      iex> prompt = %PhoenixKit.Modules.AI.Prompt{variables: []}
      iex> PhoenixKit.Modules.AI.Prompt.has_variables?(prompt)
      false
  """
  def has_variables?(%__MODULE__{variables: variables}) do
    is_list(variables) and not Enum.empty?(variables)
  end

  def has_variables?(_), do: false

  @doc """
  Returns the number of variables in a prompt.

  ## Examples

      iex> prompt = %PhoenixKit.Modules.AI.Prompt{variables: ["Name", "Age"]}
      iex> PhoenixKit.Modules.AI.Prompt.variable_count(prompt)
      2
  """
  def variable_count(%__MODULE__{variables: variables}) when is_list(variables) do
    length(variables)
  end

  def variable_count(_), do: 0

  @doc """
  Formats variables for display in the UI.

  Returns a string like "{{Name}}, {{Age}}" for easy display.

  ## Examples

      iex> prompt = %PhoenixKit.Modules.AI.Prompt{variables: ["Name", "Age"]}
      iex> PhoenixKit.Modules.AI.Prompt.format_variables_for_display(prompt)
      "{{Name}}, {{Age}}"

      iex> prompt = %PhoenixKit.Modules.AI.Prompt{variables: []}
      iex> PhoenixKit.Modules.AI.Prompt.format_variables_for_display(prompt)
      ""
  """
  def format_variables_for_display(%__MODULE__{variables: variables}) when is_list(variables) do
    Enum.map_join(variables, ", ", fn var -> "{{#{var}}}" end)
  end

  def format_variables_for_display(_), do: ""

  @doc """
  Checks if content has valid variable syntax.

  Returns `true` if all `{{...}}` patterns contain valid variable names
  (alphanumeric and underscores only), or if there are no variables.

  ## Examples

      iex> PhoenixKit.Modules.AI.Prompt.valid_content?("Hello {{Name}}!")
      true

      iex> PhoenixKit.Modules.AI.Prompt.valid_content?("No variables here")
      true

      iex> PhoenixKit.Modules.AI.Prompt.valid_content?("Hello {{User Name}}!")
      false
  """
  def valid_content?(content) when is_binary(content) do
    # Find all {{...}} patterns including potentially invalid ones
    all_patterns = Regex.scan(~r/\{\{([^}]+)\}\}/, content)

    # Check if all captured groups are valid variable names
    Enum.all?(all_patterns, fn [_full, inner] ->
      Regex.match?(~r/^\w+$/, inner)
    end)
  end

  def valid_content?(_), do: false

  @doc """
  Returns a list of invalid variable patterns in the content.

  Useful for showing validation errors in the UI.

  ## Examples

      iex> PhoenixKit.Modules.AI.Prompt.invalid_variables("Hello {{Name}}!")
      []

      iex> PhoenixKit.Modules.AI.Prompt.invalid_variables("{{User Name}} and {{ok}}")
      ["User Name"]
  """
  def invalid_variables(content) when is_binary(content) do
    ~r/\{\{([^}]+)\}\}/
    |> Regex.scan(content)
    |> Enum.map(fn [_full, inner] -> inner end)
    |> Enum.reject(fn inner -> Regex.match?(~r/^\w+$/, inner) end)
  end

  def invalid_variables(_), do: []

  @doc """
  Merges provided variables with defaults for missing ones.

  Returns a map with all required variables, using defaults for any not provided.

  ## Examples

      iex> prompt = %PhoenixKit.Modules.AI.Prompt{variables: ["Name", "Age"]}
      iex> PhoenixKit.Modules.AI.Prompt.merge_with_defaults(prompt, %{"Name" => "John"}, %{"Age" => "Unknown"})
      %{"Name" => "John", "Age" => "Unknown"}
  """
  def merge_with_defaults(%__MODULE__{variables: variables}, provided, defaults)
      when is_map(provided) and is_map(defaults) do
    variables
    |> Enum.reduce(provided, fn var, acc ->
      if Map.has_key?(acc, var) or Map.has_key?(acc, String.to_atom(var)) do
        acc
      else
        Map.put(acc, var, Map.get(defaults, var) || Map.get(defaults, String.to_atom(var)))
      end
    end)
  end

  def merge_with_defaults(_, provided, _) when is_map(provided), do: provided
  def merge_with_defaults(_, _, _), do: %{}

  # Private functions

  defp maybe_generate_slug(changeset) do
    # Always regenerate slug from name when name changes
    # (slug field is readonly in the UI, so users can't manually set it)
    case get_change(changeset, :name) do
      nil ->
        # Name didn't change, keep existing slug
        changeset

      name when is_binary(name) and name != "" ->
        # Name changed, regenerate slug
        put_change(changeset, :slug, Slug.slugify(name))

      _ ->
        # Name cleared, clear slug too
        put_change(changeset, :slug, nil)
    end
  end

  defp auto_extract_variables(changeset) do
    content = get_field(changeset, :content)

    if content do
      variables = extract_variables(content)
      put_change(changeset, :variables, variables)
    else
      changeset
    end
  end

  defp get_variable_value(variables, var_name, default) do
    # Try string key first, then atom key
    case Map.get(variables, var_name) do
      nil ->
        case Map.get(variables, String.to_atom(var_name)) do
          nil -> default
          value -> to_string(value)
        end

      value ->
        to_string(value)
    end
  rescue
    # String.to_atom can fail for invalid atoms, fall back to default
    ArgumentError -> default
  end

  defp maybe_add_ellipsis(text, original_length) when original_length > 100, do: text <> "..."
  defp maybe_add_ellipsis(text, _), do: text
end
