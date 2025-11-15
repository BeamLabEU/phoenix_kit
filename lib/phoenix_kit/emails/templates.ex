defmodule PhoenixKit.Emails.Templates do
  @moduledoc """
  Context module for managing email templates.

  This module provides the business logic and database operations for email templates,
  including CRUD operations, template rendering, variable substitution, and usage tracking.

  ## Main Functions

  - `list_templates/1` - List templates with filtering and pagination
  - `get_template/1` - Get template by ID
  - `get_template_by_name/1` - Get template by name
  - `create_template/1` - Create a new template
  - `update_template/2` - Update existing template
  - `delete_template/1` - Delete template
  - `render_template/2` - Render template with variables

  ## Examples

      # List all active templates
      Templates.list_templates(%{status: "active"})

      # Get template by name
      template = Templates.get_template_by_name("magic_link")

      # Render template with variables
      Templates.render_template(template, %{"user_name" => "John", "url" => "https://example.com"})

  """

  import Ecto.Query, warn: false
  alias PhoenixKit.Emails.Template

  require Logger

  # Get the configured repository
  defp repo do
    case PhoenixKit.Config.get(:repo) do
      {:ok, repo_module} ->
        repo_module

      :not_found ->
        raise "PhoenixKit repository not configured. Please set config :phoenix_kit, repo: YourApp.Repo"
    end
  end

  @doc """
  Lists templates with optional filtering and pagination.

  ## Parameters

  - `opts` - Keyword list with filtering options:
    - `:category` - Filter by category ("system", "marketing", "transactional")
    - `:status` - Filter by status ("active", "draft", "archived")
    - `:search` - Search in name, display_name, or description
    - `:is_system` - Filter by system templates (true/false)
    - `:limit` - Limit number of results
    - `:offset` - Offset for pagination
    - `:order_by` - Order by field (:name, :usage_count, :last_used_at, :inserted_at)
    - `:order_direction` - Order direction (:asc, :desc)

  ## Examples

      # List all templates
      Templates.list_templates()

      # List active marketing templates
      Templates.list_templates(%{category: "marketing", status: "active"})

      # Search templates
      Templates.list_templates(%{search: "welcome"})

      # Paginated results
      Templates.list_templates(%{limit: 10, offset: 20})

  """
  def list_templates(opts \\ %{}) do
    Template
    |> apply_filters(opts)
    |> apply_ordering(opts)
    |> apply_pagination(opts)
    |> repo().all()
  end

  @doc """
  Returns the count of templates matching the given filters.
  """
  def count_templates(opts \\ %{}) do
    Template
    |> apply_filters(opts)
    |> select([t], count(t.id))
    |> repo().one()
  end

  @doc """
  Gets a template by ID.

  Returns `nil` if the template does not exist.

  ## Examples

      iex> Templates.get_template(1)
      %Template{}

      iex> Templates.get_template(999)
      nil

  """
  def get_template(id) when is_integer(id) do
    repo().get(Template, id)
  end

  def get_template(_), do: nil

  @doc """
  Gets a template by ID, raising an exception if not found.

  ## Examples

      iex> Templates.get_template!(1)
      %Template{}

      iex> Templates.get_template!(999)
      ** (Ecto.NoResultsError)

  """
  def get_template!(id) do
    repo().get!(Template, id)
  end

  @doc """
  Gets a template by name.

  Returns `nil` if the template does not exist.

  ## Examples

      iex> Templates.get_template_by_name("magic_link")
      %Template{}

      iex> Templates.get_template_by_name("nonexistent")
      nil

  """
  def get_template_by_name(name) when is_binary(name) do
    Template
    |> where([t], t.name == ^name)
    |> repo().one()
  end

  def get_template_by_name(_), do: nil

  @doc """
  Gets an active template by name.

  Only returns templates with status "active".

  ## Examples

      iex> Templates.get_active_template_by_name("magic_link")
      %Template{}

  """
  def get_active_template_by_name(name) when is_binary(name) do
    Template
    |> where([t], t.name == ^name and t.status == "active")
    |> repo().one()
  end

  def get_active_template_by_name(_), do: nil

  @doc """
  Creates a new email template.

  ## Examples

      iex> Templates.create_template(%{name: "welcome", subject: "Welcome!", ...})
      {:ok, %Template{}}

      iex> Templates.create_template(%{invalid: "data"})
      {:error, %Ecto.Changeset{}}

  """
  def create_template(attrs \\ %{}) do
    %Template{}
    |> Template.changeset(attrs)
    |> repo().insert()
    |> case do
      {:ok, template} ->
        Logger.info("Created email template: #{template.name}")
        {:ok, template}

      {:error, changeset} ->
        Logger.error("Failed to create email template: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  @doc """
  Updates an existing email template.

  ## Examples

      iex> Templates.update_template(template, %{subject: "New Subject"})
      {:ok, %Template{}}

      iex> Templates.update_template(template, %{invalid: "data"})
      {:error, %Ecto.Changeset{}}

  """
  def update_template(%Template{} = template, attrs) do
    template
    |> Template.changeset(attrs)
    |> Template.version_changeset(%{
      version: template.version + 1,
      updated_by_user_id: attrs[:updated_by_user_id]
    })
    |> repo().update()
    |> case do
      {:ok, updated_template} ->
        Logger.info(
          "Updated email template: #{updated_template.name} (v#{updated_template.version})"
        )

        {:ok, updated_template}

      {:error, changeset} ->
        Logger.error("Failed to update email template: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  @doc """
  Deletes an email template.

  System templates (is_system: true) cannot be deleted.

  ## Examples

      iex> Templates.delete_template(template)
      {:ok, %Template{}}

      iex> Templates.delete_template(system_template)
      {:error, :system_template_protected}

  """
  def delete_template(%Template{is_system: true} = _template) do
    {:error, :system_template_protected}
  end

  def delete_template(%Template{} = template) do
    case repo().delete(template) do
      {:ok, deleted_template} ->
        Logger.info("Deleted email template: #{deleted_template.name}")
        {:ok, deleted_template}

      {:error, changeset} ->
        Logger.error("Failed to delete email template: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  @doc """
  Archives an email template by setting its status to "archived".

  ## Examples

      iex> Templates.archive_template(template)
      {:ok, %Template{status: "archived"}}

  """
  def archive_template(%Template{} = template, user_id \\ nil) do
    update_template(template, %{
      status: "archived",
      updated_by_user_id: user_id
    })
  end

  @doc """
  Activates an email template by setting its status to "active".

  ## Examples

      iex> Templates.activate_template(template)
      {:ok, %Template{status: "active"}}

  """
  def activate_template(%Template{} = template, user_id \\ nil) do
    update_template(template, %{
      status: "active",
      updated_by_user_id: user_id
    })
  end

  @doc """
  Clones an existing template with a new name.

  ## Examples

      iex> Templates.clone_template(template, "new_welcome_email")
      {:ok, %Template{name: "new_welcome_email"}}

  """
  def clone_template(%Template{} = template, new_name, attrs \\ %{}) do
    base_attrs = %{
      name: new_name,
      slug: String.replace(new_name, "_", "-"),
      display_name: attrs[:display_name] || "#{template.display_name} (Copy)",
      description: template.description,
      subject: template.subject,
      html_body: template.html_body,
      text_body: template.text_body,
      category: template.category,
      status: "draft",
      variables: template.variables,
      metadata: Map.merge(template.metadata, %{"cloned_from" => template.id}),
      is_system: false,
      created_by_user_id: attrs[:created_by_user_id]
    }

    final_attrs = Map.merge(base_attrs, attrs)
    create_template(final_attrs)
  end

  @doc """
  Renders a template with the provided variables.

  Returns a map with `:subject`, `:html_body`, and `:text_body` keys containing
  the rendered content with variables substituted.

  This function performs validation to ensure all template variables are properly substituted:
  - Checks for missing required variables
  - Warns if any unreplaced `{{variable}}` placeholders remain
  - Logs information about unused variables

  ## Examples

      iex> Templates.render_template(template, %{"user_name" => "John"})
      %{
        subject: "Welcome John!",
        html_body: "<h1>Welcome John!</h1>",
        text_body: "Welcome John!"
      }

  ## Validation

  If required variables are missing or templates contain unreplaced variables,
  warnings will be logged but the function will still return the rendered content.
  This allows for graceful degradation in production.

  """
  def render_template(%Template{} = template, variables \\ %{}) do
    # Extract required variables from the template
    required_vars = Template.extract_variables(template)
    provided_vars = Map.keys(variables)

    # Check for missing variables
    missing_vars = required_vars -- provided_vars

    if missing_vars != [] do
      Logger.warning(
        "Template '#{template.name}' is missing required variables: #{Enum.join(missing_vars, ", ")}"
      )
    end

    # Check for unused variables (provided but not used in template)
    unused_vars = provided_vars -- required_vars

    if unused_vars != [] do
      Logger.info(
        "Template '#{template.name}' has unused variables: #{Enum.join(unused_vars, ", ")}"
      )
    end

    # Perform variable substitution
    rendered_template = Template.substitute_variables(template, variables)

    # Check for unreplaced variables in rendered output
    validate_rendered_content(template.name, rendered_template)

    %{
      subject: rendered_template.subject,
      html_body: rendered_template.html_body,
      text_body: rendered_template.text_body
    }
  end

  # Private helper to validate rendered content for unreplaced variables
  defp validate_rendered_content(template_name, rendered) do
    # Check each field for unreplaced {{variable}} patterns
    fields_with_issues =
      [
        {:subject, rendered.subject},
        {:html_body, rendered.html_body},
        {:text_body, rendered.text_body}
      ]
      |> Enum.filter(fn {_field, content} ->
        String.contains?(content, "{{")
      end)

    if fields_with_issues != [] do
      field_names = Enum.map(fields_with_issues, fn {field, _} -> field end)

      Logger.warning(
        "Template '#{template_name}' contains unreplaced variables in: #{Enum.join(field_names, ", ")}"
      )
    end
  end

  @doc """
  Sends an email using a template.

  This is a convenience wrapper around `PhoenixKit.Mailer.send_from_template/4`
  that provides a cleaner API for sending templated emails.

  ## Parameters

  - `template_name` - Name of the template (e.g., "welcome_email")
  - `recipient` - Email address or {name, email} tuple
  - `variables` - Map of template variables
  - `opts` - Additional options (see `PhoenixKit.Mailer.send_from_template/4`)

  ## Examples

      # Send welcome email
      Templates.send_email("welcome_email", user.email, %{
        "user_name" => user.name,
        "activation_url" => activation_url
      })

      # Send with tracking
      Templates.send_email(
        "order_confirmation",
        customer.email,
        %{"order_number" => order.number},
        user_id: customer.id,
        metadata: %{order_id: order.id}
      )
  """
  def send_email(template_name, recipient, variables \\ %{}, opts \\ []) do
    PhoenixKit.Mailer.send_from_template(template_name, recipient, variables, opts)
  end

  @doc """
  Increments the usage count for a template and updates last_used_at.

  This should be called whenever a template is used to send an email.

  ## Examples

      iex> Templates.track_usage(template)
      {:ok, %Template{usage_count: 1}}

  """
  def track_usage(%Template{} = template) do
    template
    |> Template.usage_changeset(%{
      usage_count: template.usage_count + 1,
      last_used_at: DateTime.utc_now()
    })
    |> repo().update()
  end

  @doc """
  Gets template statistics for dashboard display.

  Returns a map with various statistics about templates.

  ## Examples

      iex> Templates.get_template_stats()
      %{
        total_templates: 10,
        active_templates: 8,
        draft_templates: 1,
        archived_templates: 1,
        system_templates: 4,
        most_used: %Template{},
        categories: %{"system" => 4, "transactional" => 6}
      }

  """
  def get_template_stats do
    base_query = from(t in Template)

    total_templates = repo().aggregate(base_query, :count, :id)

    active_templates =
      base_query
      |> where([t], t.status == "active")
      |> repo().aggregate(:count, :id)

    draft_templates =
      base_query
      |> where([t], t.status == "draft")
      |> repo().aggregate(:count, :id)

    archived_templates =
      base_query
      |> where([t], t.status == "archived")
      |> repo().aggregate(:count, :id)

    system_templates =
      base_query
      |> where([t], t.is_system == true)
      |> repo().aggregate(:count, :id)

    most_used =
      base_query
      |> where([t], t.usage_count > 0)
      |> order_by([t], desc: t.usage_count)
      |> limit(1)
      |> repo().one()

    categories =
      base_query
      |> group_by([t], t.category)
      |> select([t], {t.category, count(t.id)})
      |> repo().all()
      |> Enum.into(%{})

    %{
      total_templates: total_templates,
      active_templates: active_templates,
      draft_templates: draft_templates,
      archived_templates: archived_templates,
      system_templates: system_templates,
      most_used: most_used,
      categories: categories
    }
  end

  @doc """
  Seeds the database with system email templates.

  This function creates the default system templates for authentication
  and core functionality.

  ## Examples

      iex> Templates.seed_system_templates()
      {:ok, [%Template{}, ...]}

  """
  def seed_system_templates do
    system_templates = [
      %{
        name: "magic_link",
        slug: "magic-link",
        display_name: "Magic Link Authentication",
        description: "Secure login link email for passwordless authentication",
        subject: "Your secure login link",
        html_body: magic_link_html_template(),
        text_body: magic_link_text_template(),
        category: "system",
        status: "active",
        is_system: true,
        variables: %{
          "user_email" => "User's email address",
          "magic_link_url" => "URL for magic link authentication"
        }
      },
      %{
        name: "register",
        slug: "register",
        display_name: "Account Confirmation",
        description: "Email sent to confirm user registration",
        subject: "Confirm your account",
        html_body: register_html_template(),
        text_body: register_text_template(),
        category: "system",
        status: "active",
        is_system: true,
        variables: %{
          "user_email" => "User's email address",
          "confirmation_url" => "URL for account confirmation"
        }
      },
      %{
        name: "reset_password",
        slug: "reset-password",
        display_name: "Password Reset",
        description: "Email sent for password reset requests",
        subject: "Reset your password",
        html_body: reset_password_html_template(),
        text_body: reset_password_text_template(),
        category: "system",
        status: "active",
        is_system: true,
        variables: %{
          "user_email" => "User's email address",
          "reset_url" => "URL for password reset"
        }
      },
      %{
        name: "test_email",
        slug: "test-email",
        display_name: "Test Email",
        description: "Test email for verifying email tracking system",
        subject: "Test Tracking Email - {{timestamp}}",
        html_body: test_email_html_template(),
        text_body: test_email_text_template(),
        category: "system",
        status: "active",
        is_system: true,
        variables: %{
          "recipient_email" => "Recipient's email address",
          "timestamp" => "Current timestamp",
          "test_link_url" => "URL for testing link tracking"
        }
      },
      %{
        name: "update_email",
        slug: "update-email",
        display_name: "Email Change Confirmation",
        description: "Email sent to confirm email address changes",
        subject: "Confirm your email change",
        html_body: update_email_html_template(),
        text_body: update_email_text_template(),
        category: "system",
        status: "active",
        is_system: true,
        variables: %{
          "user_email" => "User's email address",
          "update_url" => "URL for email update confirmation"
        }
      }
    ]

    results =
      Enum.map(system_templates, fn template_attrs ->
        case get_template_by_name(template_attrs.name) do
          nil ->
            create_template(template_attrs)

          existing_template ->
            {:ok, existing_template}
        end
      end)

    if Enum.all?(results, fn {status, _} -> status == :ok end) do
      templates = Enum.map(results, fn {:ok, template} -> template end)
      Logger.info("Successfully seeded #{length(templates)} system email templates")
      {:ok, templates}
    else
      errors = Enum.filter(results, fn {status, _} -> status == :error end)
      Logger.error("Failed to seed some system templates: #{inspect(errors)}")
      {:error, :seed_failed}
    end
  end

  # Private helper functions

  defp apply_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:category, category}, q when is_binary(category) ->
        where(q, [t], t.category == ^category)

      {:status, status}, q when is_binary(status) ->
        where(q, [t], t.status == ^status)

      {:is_system, is_system}, q when is_boolean(is_system) ->
        where(q, [t], t.is_system == ^is_system)

      {:search, search}, q when is_binary(search) and search != "" ->
        search_term = "%#{search}%"

        where(
          q,
          [t],
          ilike(t.name, ^search_term) or
            ilike(t.display_name, ^search_term) or
            ilike(t.description, ^search_term)
        )

      _, q ->
        q
    end)
  end

  defp apply_ordering(query, opts) do
    case {opts[:order_by], opts[:order_direction]} do
      {field, direction}
      when field in [:name, :usage_count, :last_used_at, :inserted_at] and
             direction in [:asc, :desc] ->
        order_by(query, [t], [{^direction, field(t, ^field)}])

      {field, _} when field in [:name, :usage_count, :last_used_at, :inserted_at] ->
        order_by(query, [t], asc: field(t, ^field))

      _ ->
        order_by(query, [t], desc: :inserted_at)
    end
  end

  defp apply_pagination(query, opts) do
    query =
      case opts[:limit] do
        limit when is_integer(limit) and limit > 0 ->
          limit(query, ^limit)

        _ ->
          query
      end

    case opts[:offset] do
      offset when is_integer(offset) and offset >= 0 ->
        offset(query, ^offset)

      _ ->
        query
    end
  end

  # Template content functions (extracted from existing mailer)

  @doc """
  Returns the HTML template for magic link emails.
  """
  def magic_link_html_template do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Your Secure Login Link</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; }
        .header { text-align: center; margin-bottom: 30px; }
        .button { display: inline-block; padding: 12px 24px; background-color: #3b82f6; color: white; text-decoration: none; border-radius: 6px; font-weight: 500; }
        .button:hover { background-color: #2563eb; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #e5e7eb; font-size: 14px; color: #6b7280; }
        .warning { background-color: #fef3c7; border: 1px solid #f59e0b; border-radius: 6px; padding: 16px; margin: 20px 0; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>Secure Login Link</h1>
        </div>

        <p>Hi {{user_email}},</p>

        <p>Click the button below to securely log in to your account:</p>

        <p style="text-align: center; margin: 30px 0;">
          <a href="{{magic_link_url}}" class="button">Log In Securely</a>
        </p>

        <div class="warning">
          <strong>⚠️ Important:</strong> This link will expire in 15 minutes and can only be used once.
        </div>

        <p>If you didn't request this login link, you can safely ignore this email.</p>

        <p>For your security, never share this link with anyone.</p>

        <div class="footer">
          <p>If the button above doesn't work, you can copy and paste this link into your browser:</p>
          <p><a href="{{magic_link_url}}">{{magic_link_url}}</a></p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  @doc """
  Returns the text template for magic link emails.
  """
  def magic_link_text_template do
    """
    Secure Login Link

    Hi {{user_email}},

    Click the link below to securely log in to your account:

    {{magic_link_url}}

    ⚠️ Important: This link will expire in 15 minutes and can only be used once.

    If you didn't request this login link, you can safely ignore this email.

    For your security, never share this link with anyone.
    """
  end

  @doc """
  Returns the HTML template for registration confirmation emails.
  """
  def register_html_template do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Confirm Your Account</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; }
        .header { text-align: center; margin-bottom: 30px; }
        .button { display: inline-block; padding: 12px 24px; background-color: #3b82f6; color: white; text-decoration: none; border-radius: 6px; font-weight: 500; }
        .button:hover { background-color: #2563eb; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #e5e7eb; font-size: 14px; color: #6b7280; }
        .info-box { background-color: #f0f9ff; border: 1px solid #0ea5e9; border-radius: 6px; padding: 16px; margin: 20px 0; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>Welcome! Please confirm your account</h1>
        </div>

        <p>Hi {{user_email}},</p>

        <p>Thank you for creating an account! To complete your registration, please confirm your email address by clicking the button below:</p>

        <p style="text-align: center; margin: 30px 0;">
          <a href="{{confirmation_url}}" class="button">Confirm My Account</a>
        </p>

        <div class="info-box">
          <strong>ℹ️ Note:</strong> This confirmation link is secure and will verify your email address.
        </div>

        <p>If you didn't create an account with us, you can safely ignore this email.</p>

        <div class="footer">
          <p>If the button above doesn't work, you can copy and paste this link into your browser:</p>
          <p><a href="{{confirmation_url}}">{{confirmation_url}}</a></p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  @doc """
  Returns the text template for registration confirmation emails.
  """
  def register_text_template do
    """
    ==============================

    Hi {{user_email}},

    You can confirm your account by visiting the URL below:

    {{confirmation_url}}

    If you didn't create an account with us, please ignore this.

    ==============================
    """
  end

  @doc """
  Returns the HTML template for password reset emails.
  """
  def reset_password_html_template do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Reset Your Password</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; }
        .header { text-align: center; margin-bottom: 30px; }
        .button { display: inline-block; padding: 12px 24px; background-color: #dc2626; color: white; text-decoration: none; border-radius: 6px; font-weight: 500; }
        .button:hover { background-color: #b91c1c; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #e5e7eb; font-size: 14px; color: #6b7280; }
        .warning { background-color: #fef3c7; border: 1px solid #f59e0b; border-radius: 6px; padding: 16px; margin: 20px 0; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>Password Reset Request</h1>
        </div>

        <p>Hi {{user_email}},</p>

        <p>We received a request to reset your password. Click the button below to create a new password:</p>

        <p style="text-align: center; margin: 30px 0;">
          <a href="{{reset_url}}" class="button">Reset My Password</a>
        </p>

        <div class="warning">
          <strong>⚠️ Security Notice:</strong> This password reset link will expire soon for your security.
        </div>

        <p>If you didn't request this password reset, you can safely ignore this email. Your password will remain unchanged.</p>

        <div class="footer">
          <p>If the button above doesn't work, you can copy and paste this link into your browser:</p>
          <p><a href="{{reset_url}}">{{reset_url}}</a></p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  @doc """
  Returns the text template for password reset emails.
  """
  def reset_password_text_template do
    """
    ==============================

    Hi {{user_email}},

    You can reset your password by visiting the URL below:

    {{reset_url}}

    If you didn't request this change, please ignore this.

    ==============================
    """
  end

  @doc """
  Returns the HTML template for test emails.
  """
  def test_email_html_template do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Test Tracking Email</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; background-color: #f8f9fa; }
        .header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 30px; text-align: center; border-radius: 8px 8px 0 0; }
        .content { padding: 30px; }
        .button { display: inline-block; padding: 12px 24px; background-color: #3b82f6; color: white; text-decoration: none; border-radius: 6px; font-weight: 500; margin: 10px 5px; }
        .button:hover { background-color: #2563eb; }
        .info-box { background-color: #f0f9ff; border: 1px solid #0ea5e9; border-radius: 6px; padding: 16px; margin: 20px 0; }
        .success-box { background-color: #f0fdf4; border: 1px solid #22c55e; border-radius: 6px; padding: 16px; margin: 20px 0; }
        .footer { background-color: #f8f9fa; padding: 20px; border-radius: 0 0 8px 8px; font-size: 14px; color: #6b7280; }
        .test-links { margin: 20px 0; }
        .test-links a { margin-right: 15px; }
        .tracking-info { font-family: monospace; background: #f3f4f6; padding: 10px; border-radius: 4px; margin: 10px 0; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>📧 Test Tracking Email</h1>
          <p>Email Tracking System Verification</p>
        </div>

        <div class="content">
          <div class="success-box">
            <strong>✅ Success!</strong> This test email was sent successfully through the PhoenixKit email tracking system.
          </div>

          <p>Hello,</p>

          <p>This is a test email to verify that your email tracking system is working correctly. If you received this email, it means:</p>

          <ul>
            <li>✅ Email delivery is working</li>
            <li>✅ AWS SES configuration is correct (if using SES)</li>
            <li>✅ Email tracking is enabled and logging</li>
            <li>✅ Configuration set is properly configured</li>
          </ul>

          <div class="info-box">
            <strong>📊 Tracking Information:</strong>
            <div class="tracking-info">
              Recipient: {{recipient_email}}<br>
              Sent at: {{timestamp}}<br>
              Campaign: test<br>
              Template: test_email
            </div>
          </div>

          <div class="test-links">
            <p><strong>Test these tracking features:</strong></p>
            <a href="{{test_link_url}}?test=link1" class="button">Test Link 1</a>
            <a href="{{test_link_url}}?test=link2" class="button">Test Link 2</a>
            <a href="{{test_link_url}}?test=link3" class="button">Test Link 3</a>
          </div>

          <p>Click any of the buttons above to test link tracking. Then check your emails in the admin panel to see the tracking data.</p>

        </div>

        <div class="footer">
          <p>This is an automated test email from PhoenixKit Email Tracking System.</p>
          <p>Check your admin panel at: <a href="{{test_link_url}}">{{test_link_url}}</a></p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  @doc """
  Returns the text template for test emails.
  """
  def test_email_text_template do
    """
    TEST TRACKING EMAIL - EMAIL SYSTEM VERIFICATION

    Success! This test email was sent successfully through the PhoenixKit email tracking system.

    Hello,

    This is a test email to verify that your email tracking system is working correctly. If you received this email, it means:

    ✅ Email delivery is working
    ✅ AWS SES configuration is correct (if using SES)
    ✅ Email tracking is enabled and logging
    ✅ Configuration set is properly configured

    TRACKING INFORMATION:
    ---------------------
    Recipient: {{recipient_email}}
    Sent at: {{timestamp}}
    Campaign: test
    Template: test_email

    TEST LINKS:
    -----------
    Test these tracking features by visiting:

    Test Link 1: {{test_link_url}}?test=link1
    Test Link 2: {{test_link_url}}?test=link2
    Test Link 3: {{test_link_url}}?test=link3

    Click any of the links above to test link tracking. Then check your emails in the admin panel to see the tracking data.

    ---
    This is an automated test email from PhoenixKit Email Tracking System.
    Check your admin panel at: {{test_link_url}}
    """
  end

  @doc """
  Returns the HTML template for email update confirmation emails.
  """
  def update_email_html_template do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Confirm Email Change</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; }
        .header { text-align: center; margin-bottom: 30px; }
        .button { display: inline-block; padding: 12px 24px; background-color: #059669; color: white; text-decoration: none; border-radius: 6px; font-weight: 500; }
        .button:hover { background-color: #047857; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #e5e7eb; font-size: 14px; color: #6b7280; }
        .info-box { background-color: #f0fdf4; border: 1px solid #22c55e; border-radius: 6px; padding: 16px; margin: 20px 0; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>Confirm Your Email Change</h1>
        </div>

        <p>Hi {{user_email}},</p>

        <p>We received a request to change your email address. To complete this change, please confirm your new email address by clicking the button below:</p>

        <p style="text-align: center; margin: 30px 0;">
          <a href="{{update_url}}" class="button">Confirm Email Change</a>
        </p>

        <div class="info-box">
          <strong>✓ Verification Required:</strong> This step ensures your new email address is valid and accessible.
        </div>

        <p>If you didn't request this email change, you can safely ignore this message. Your current email address will remain unchanged.</p>

        <div class="footer">
          <p>If the button above doesn't work, you can copy and paste this link into your browser:</p>
          <p><a href="{{update_url}}">{{update_url}}</a></p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  @doc """
  Returns the text template for email update confirmation emails.
  """
  def update_email_text_template do
    """
    ==============================

    Hi {{user_email}},

    You can change your email by visiting the URL below:

    {{update_url}}

    If you didn't request this change, please ignore this.

    ==============================
    """
  end
end
