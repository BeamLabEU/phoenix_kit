defmodule PhoenixKit.Modules.Emails.Template do
  @moduledoc """
  Email template schema for managing reusable email templates.

  This module defines the structure and validations for email templates that can be
  used throughout the application. Templates support variable substitution and
  categorization for better organization.

  ## Template Variables

  Templates support variable substitution using the `{{variable_name}}` syntax.
  Common variables include:

  - `{{email}}` - User's email address
  - `{{url}}` - Action URL (magic link, confirmation, etc.)
  - `{{timestamp}}` - Current timestamp
  - `{{user_name}}` - User's display name

  ## Categories

  - **system** - Core authentication and system emails (protected)
  - **marketing** - Promotional and marketing communications
  - **transactional** - Order confirmations, notifications, etc.
  - **notification** - Event-driven notifications (new posts, comments, etc.)

  ## Source Modules

  Templates can be tagged with a source module in the `metadata` field to track
  which part of the application sends the email:

  - **users** - User management (magic_link, password_reset, email_confirmation)
  - **billing** - Billing module (invoices, receipts, payment notifications)
  - **publishing** - Publishing module (new posts, comments)
  - **entities** - Entities module (entity notifications)
  - **admin** - Admin functions (test emails, manual sends)
  - **custom** - Custom/user-defined emails

  ## Metadata Structure

  The `metadata` field can contain:

      %{
        "source_module" => "users",    # Source module identifier
        "priority" => "high",           # Email priority (optional)
        "requires_user" => true         # Whether user_id is required (optional)
      }

  ## Status

  - **active** - Template is live and can be used
  - **draft** - Template is being edited
  - **archived** - Template is no longer active but preserved

  ## Examples

      # Create a new template
      %EmailTemplate{}
      |> EmailTemplate.changeset(%{
        name: "welcome_email",
        slug: "welcome-email",
        display_name: "Welcome Email",
        subject: "Welcome to {{app_name}}!",
        html_body: "<h1>Welcome {{user_name}}!</h1>",
        text_body: "Welcome {{user_name}}!",
        category: "transactional",
        status: "active"
      })

  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t(),
          slug: String.t(),
          display_name: String.t(),
          description: String.t() | nil,
          subject: String.t(),
          html_body: String.t(),
          text_body: String.t(),
          category: String.t(),
          status: String.t(),
          variables: map(),
          metadata: map(),
          usage_count: integer(),
          last_used_at: DateTime.t() | nil,
          version: integer(),
          is_system: boolean(),
          created_by_user_id: integer() | nil,
          updated_by_user_id: integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  # Valid categories for email templates
  @valid_categories ["system", "marketing", "transactional", "notification"]

  # Valid statuses for email templates
  @valid_statuses ["active", "draft", "archived"]

  # Valid source modules for email templates
  @valid_source_modules ["users", "billing", "publishing", "entities", "admin", "custom"]

  # Common template variables that can be used
  @common_variables [
    "email",
    "user_name",
    "url",
    "timestamp",
    "app_name",
    "support_email",
    "company_name"
  ]

  schema "phoenix_kit_email_templates" do
    field :uuid, Ecto.UUID, read_after_writes: true
    field :name, :string
    field :slug, :string
    field :display_name, :string
    field :description, :string
    field :subject, :string
    field :html_body, :string
    field :text_body, :string
    field :category, :string, default: "transactional"
    field :status, :string, default: "draft"
    field :variables, :map, default: %{}
    field :metadata, :map, default: %{}
    field :usage_count, :integer, default: 0
    field :last_used_at, :utc_datetime_usec
    field :version, :integer, default: 1
    field :is_system, :boolean, default: false
    field :created_by_user_id, :integer
    field :updated_by_user_id, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the list of valid categories for email templates.
  """
  def valid_categories, do: @valid_categories

  @doc """
  Returns the list of valid statuses for email templates.
  """
  def valid_statuses, do: @valid_statuses

  @doc """
  Returns the list of common template variables.
  """
  def common_variables, do: @common_variables

  @doc """
  Returns the list of valid source modules for email templates.
  """
  def valid_source_modules, do: @valid_source_modules

  @doc """
  Gets the source module from a template's metadata.

  Returns the source_module value if present, otherwise "custom".

  ## Examples

      iex> template = %EmailTemplate{metadata: %{"source_module" => "auth"}}
      iex> EmailTemplate.get_source_module(template)
      "auth"

      iex> template = %EmailTemplate{metadata: %{}}
      iex> EmailTemplate.get_source_module(template)
      "custom"

  """
  def get_source_module(%__MODULE__{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "source_module", "custom")
  end

  def get_source_module(_), do: "custom"

  @doc """
  Sets the source module in a template's metadata.

  Returns updated metadata map with source_module set.

  ## Examples

      iex> EmailTemplate.set_source_module(%{}, "auth")
      %{"source_module" => "auth"}

  """
  def set_source_module(metadata, source_module)
      when is_map(metadata) and source_module in @valid_source_modules do
    Map.put(metadata, "source_module", source_module)
  end

  def set_source_module(metadata, _source_module), do: metadata

  @doc """
  Creates a changeset for email template creation and updates.

  ## Parameters

  - `template` - The email template struct (new or existing)
  - `attrs` - Map of attributes to change

  ## Required Fields

  - `:name` - Unique template identifier
  - `:slug` - URL-friendly identifier
  - `:display_name` - Human-readable name
  - `:subject` - Email subject line
  - `:html_body` - HTML version of email
  - `:text_body` - Plain text version of email

  ## Validations

  - Name must be unique and follow snake_case format
  - Slug must be unique and URL-friendly
  - Category must be one of the valid categories
  - Status must be one of the valid statuses
  - Subject and body fields cannot be empty
  - Variables must be a valid map
  """
  def changeset(template, attrs) do
    template
    |> cast(attrs, [
      :name,
      :slug,
      :display_name,
      :description,
      :subject,
      :html_body,
      :text_body,
      :category,
      :status,
      :variables,
      :metadata,
      :is_system,
      :created_by_user_id,
      :updated_by_user_id
    ])
    |> auto_generate_slug()
    |> validate_required([
      :name,
      :slug,
      :display_name,
      :subject,
      :html_body,
      :text_body,
      :category,
      :status
    ])
    |> validate_length(:name, min: 2, max: 100)
    |> validate_length(:slug, min: 2, max: 100)
    |> validate_length(:display_name, min: 2, max: 200)
    |> validate_length(:subject, min: 1, max: 300)
    |> validate_length(:html_body, min: 1)
    |> validate_length(:text_body, min: 1)
    |> validate_inclusion(:category, @valid_categories)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_format(:name, ~r/^[a-z][a-z0-9_]*$/,
      message:
        "must start with a letter and contain only lowercase letters, numbers, and underscores"
    )
    |> validate_format(:slug, ~r/^[a-z][a-z0-9-]*$/,
      message: "must start with a letter and contain only lowercase letters, numbers, and hyphens"
    )
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
    |> validate_template_variables()
  end

  @doc """
  Creates a changeset for updating template usage statistics.
  """
  def usage_changeset(template, attrs \\ %{}) do
    template
    |> cast(attrs, [:usage_count, :last_used_at])
    |> validate_number(:usage_count, greater_than_or_equal_to: 0)
  end

  @doc """
  Creates a changeset for updating template version.
  """
  def version_changeset(template, attrs \\ %{}) do
    template
    |> cast(attrs, [:version, :updated_by_user_id])
    |> validate_number(:version, greater_than: 0)
  end

  @doc """
  Extracts variables from template content (subject, html_body, text_body).

  Returns a list of unique variable names found in the template.

  ## Examples

      iex> template = %EmailTemplate{
      ...>   subject: "Welcome {{user_name}}!",
      ...>   html_body: "<p>Hi {{user_name}}, click {{url}}</p>",
      ...>   text_body: "Hi {{user_name}}, visit {{url}}"
      ...> }
      iex> EmailTemplate.extract_variables(template)
      ["user_name", "url"]

  """
  def extract_variables(%__MODULE__{} = template) do
    content = "#{template.subject} #{template.html_body} #{template.text_body}"

    Regex.scan(~r/\{\{([^}]+)\}\}/, content)
    |> Enum.map(fn [_, var] -> String.trim(var) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Substitutes variables in template content with provided values.

  ## Parameters

  - `template` - The email template
  - `variables` - Map of variable names to values

  Returns a new template struct with variables substituted.

  ## Examples

      iex> template = %EmailTemplate{
      ...>   subject: "Welcome {{user_name}}!",
      ...>   html_body: "<p>Hi {{user_name}}</p>"
      ...> }
      iex> result = EmailTemplate.substitute_variables(template, %{"user_name" => "John"})
      iex> result.subject
      "Welcome John!"

  """
  def substitute_variables(%__MODULE__{} = template, variables) when is_map(variables) do
    %{
      template
      | subject: substitute_string(template.subject, variables),
        html_body: substitute_string(template.html_body, variables),
        text_body: substitute_string(template.text_body, variables)
    }
  end

  # Private helper functions

  # Automatically generate slug from name if not provided
  defp auto_generate_slug(changeset) do
    slug = get_change(changeset, :slug) || get_field(changeset, :slug)

    case slug do
      s when s in [nil, ""] ->
        name = get_change(changeset, :name) || get_field(changeset, :name)

        case name do
          n when is_binary(n) and n != "" ->
            put_change(changeset, :slug, String.replace(n, "_", "-"))

          _ ->
            changeset
        end

      _ ->
        changeset
    end
  end

  # Validate that template variables are correctly formatted
  defp validate_template_variables(changeset) do
    case get_field(changeset, :variables) do
      nil ->
        changeset

      variables when is_map(variables) ->
        # Extract variables from template content and validate against declared variables
        case {get_field(changeset, :subject), get_field(changeset, :html_body),
              get_field(changeset, :text_body)} do
          {subject, html_body, text_body}
          when is_binary(subject) and is_binary(html_body) and is_binary(text_body) ->
            template = %__MODULE__{
              subject: subject,
              html_body: html_body,
              text_body: text_body
            }

            extracted_vars = extract_variables(template)
            declared_vars = Map.keys(variables)

            # Check for undefined variables in template
            undefined_vars = extracted_vars -- declared_vars

            if Enum.empty?(undefined_vars) do
              changeset
            else
              add_error(
                changeset,
                :variables,
                "Template uses undefined variables: #{Enum.join(undefined_vars, ", ")}"
              )
            end

          _ ->
            changeset
        end

      _ ->
        add_error(changeset, :variables, "must be a valid map")
    end
  end

  # Substitute variables in a string
  defp substitute_string(content, variables) when is_binary(content) and is_map(variables) do
    Enum.reduce(variables, content, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end

  defp substitute_string(content, _variables), do: content
end
