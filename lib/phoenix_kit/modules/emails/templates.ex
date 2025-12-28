defmodule PhoenixKit.Modules.Emails.Templates do
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
  alias PhoenixKit.Modules.Emails.Template

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
        },
        metadata: %{"source_module" => "users"}
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
        },
        metadata: %{"source_module" => "users"}
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
        },
        metadata: %{"source_module" => "users"}
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
        },
        metadata: %{"source_module" => "admin"}
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
        },
        metadata: %{"source_module" => "users"}
      },
      %{
        name: "billing_invoice",
        slug: "billing-invoice",
        display_name: "Billing Invoice",
        description: "Invoice email sent to customers for payment",
        subject: "Invoice {{invoice_number}} - {{company_name}}",
        html_body: billing_invoice_html_template(),
        text_body: billing_invoice_text_template(),
        category: "transactional",
        status: "active",
        is_system: true,
        variables: %{
          "user_email" => "Customer's email address",
          "user_name" => "Customer's name",
          "invoice_number" => "Invoice number",
          "invoice_date" => "Invoice date",
          "due_date" => "Payment due date",
          "subtotal" => "Subtotal amount",
          "tax_amount" => "Tax amount",
          "total" => "Total amount",
          "currency" => "Currency code",
          "line_items_html" => "HTML table of line items",
          "line_items_text" => "Text list of line items",
          "company_name" => "Company name",
          "company_address" => "Company address",
          "company_vat" => "Company VAT number",
          "bank_name" => "Bank name",
          "bank_iban" => "Bank IBAN",
          "bank_swift" => "Bank SWIFT/BIC",
          "payment_terms" => "Payment terms",
          "invoice_url" => "URL to view invoice online"
        },
        metadata: %{"source_module" => "billing"}
      },
      %{
        name: "billing_receipt",
        slug: "billing-receipt",
        display_name: "Billing Receipt",
        description: "Receipt email sent to customers after payment confirmation",
        subject: "Receipt {{receipt_number}} - {{company_name}}",
        html_body: billing_receipt_html_template(),
        text_body: billing_receipt_text_template(),
        category: "transactional",
        status: "active",
        is_system: true,
        variables: %{
          "user_email" => "Customer's email address",
          "user_name" => "Customer's name",
          "receipt_number" => "Receipt number",
          "invoice_number" => "Original invoice number",
          "payment_date" => "Date of payment",
          "subtotal" => "Subtotal amount",
          "tax_amount" => "Tax amount",
          "total" => "Total amount",
          "paid_amount" => "Amount paid",
          "currency" => "Currency code",
          "line_items_html" => "HTML table of line items",
          "line_items_text" => "Text list of line items",
          "company_name" => "Company name",
          "company_address" => "Company address",
          "company_vat" => "Company VAT number",
          "receipt_url" => "URL to view receipt online"
        },
        metadata: %{"source_module" => "billing"}
      },
      %{
        name: "billing_credit_note",
        slug: "billing-credit-note",
        display_name: "Billing Credit Note",
        description: "Credit note email sent to customers when a refund is issued",
        subject: "Credit Note {{credit_note_number}} - Refund Issued - {{company_name}}",
        html_body: billing_credit_note_html_template(),
        text_body: billing_credit_note_text_template(),
        category: "transactional",
        status: "active",
        is_system: true,
        variables: %{
          "user_email" => "Customer's email address",
          "user_name" => "Customer's name",
          "credit_note_number" => "Credit note number",
          "invoice_number" => "Original invoice number",
          "refund_date" => "Date of refund",
          "refund_amount" => "Refund amount",
          "refund_reason" => "Reason for refund",
          "transaction_number" => "Transaction reference number",
          "currency" => "Currency code",
          "company_name" => "Company name",
          "company_address" => "Company address",
          "company_vat" => "Company VAT number",
          "credit_note_url" => "URL to view credit note online"
        },
        metadata: %{"source_module" => "billing"}
      },
      %{
        name: "billing_payment_confirmation",
        slug: "billing-payment-confirmation",
        display_name: "Billing Payment Confirmation",
        description: "Payment confirmation email sent to customers when a payment is received",
        subject: "Payment Received - {{confirmation_number}} - {{company_name}}",
        html_body: billing_payment_confirmation_html_template(),
        text_body: billing_payment_confirmation_text_template(),
        category: "transactional",
        status: "active",
        is_system: true,
        variables: %{
          "user_email" => "Customer's email address",
          "user_name" => "Customer's name",
          "confirmation_number" => "Payment confirmation number",
          "invoice_number" => "Invoice number",
          "payment_date" => "Date of payment",
          "payment_amount" => "Payment amount",
          "payment_method" => "Payment method",
          "transaction_number" => "Transaction reference number",
          "invoice_total" => "Invoice total",
          "total_paid" => "Total paid so far",
          "remaining_balance" => "Remaining balance",
          "is_final_payment" => "Whether this is the final payment",
          "currency" => "Currency code",
          "company_name" => "Company name",
          "company_address" => "Company address",
          "payment_url" => "URL to view payment confirmation online"
        },
        metadata: %{"source_module" => "billing"}
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

  @doc """
  Returns the HTML template for billing invoice emails.
  """
  def billing_invoice_html_template do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Invoice {{invoice_number}}</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; background-color: #f8f9fa; margin: 0; padding: 20px; }
        .container { max-width: 800px; margin: 0 auto; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .header { background: linear-gradient(135deg, #1e3a5f 0%, #2563eb 100%); color: white; padding: 30px; }
        .header h1 { margin: 0 0 10px 0; font-size: 28px; }
        .header .invoice-number { font-size: 18px; opacity: 0.9; }
        .content { padding: 30px; }
        .invoice-meta { display: flex; justify-content: space-between; margin-bottom: 30px; padding-bottom: 20px; border-bottom: 2px solid #e5e7eb; }
        .invoice-meta .column { flex: 1; }
        .invoice-meta h3 { margin: 0 0 10px 0; color: #6b7280; font-size: 12px; text-transform: uppercase; letter-spacing: 1px; }
        .invoice-meta p { margin: 0; line-height: 1.8; }
        .line-items { width: 100%; border-collapse: collapse; margin: 20px 0; }
        .line-items th { background: #f3f4f6; padding: 12px 15px; text-align: left; font-weight: 600; color: #374151; border-bottom: 2px solid #e5e7eb; }
        .line-items td { padding: 12px 15px; border-bottom: 1px solid #e5e7eb; }
        .line-items .text-right { text-align: right; }
        .line-items .item-name { font-weight: 500; }
        .line-items .item-desc { font-size: 13px; color: #6b7280; }
        .totals { margin-top: 20px; }
        .totals-table { width: 300px; margin-left: auto; }
        .totals-table td { padding: 8px 15px; }
        .totals-table .label { text-align: right; color: #6b7280; }
        .totals-table .value { text-align: right; font-weight: 500; }
        .totals-table .total-row { font-size: 18px; font-weight: 700; border-top: 2px solid #1e3a5f; }
        .totals-table .total-row td { padding-top: 15px; color: #1e3a5f; }
        .bank-details { background: #f0f9ff; border: 1px solid #0ea5e9; border-radius: 8px; padding: 20px; margin: 30px 0; }
        .bank-details h3 { margin: 0 0 15px 0; color: #0369a1; }
        .bank-details table { width: 100%; }
        .bank-details td { padding: 5px 0; }
        .bank-details .label { color: #6b7280; width: 120px; }
        .bank-details .value { font-family: monospace; font-weight: 500; }
        .due-date-box { background: #fef3c7; border: 1px solid #f59e0b; border-radius: 8px; padding: 15px 20px; margin: 20px 0; text-align: center; }
        .due-date-box strong { color: #b45309; }
        .button { display: inline-block; padding: 14px 28px; background-color: #2563eb; color: white; text-decoration: none; border-radius: 6px; font-weight: 600; margin: 20px 0; }
        .button:hover { background-color: #1d4ed8; }
        .footer { background: #f8f9fa; padding: 20px 30px; font-size: 13px; color: #6b7280; border-top: 1px solid #e5e7eb; }
        .footer .company-info { margin-bottom: 15px; }
        .footer .company-name { font-weight: 600; color: #374151; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>INVOICE</h1>
          <div class="invoice-number">{{invoice_number}}</div>
        </div>

        <div class="content">
          <div class="invoice-meta">
            <div class="column">
              <h3>Bill To</h3>
              <p>
                <strong>{{user_name}}</strong><br>
                {{user_email}}
              </p>
            </div>
            <div class="column" style="text-align: right;">
              <h3>Invoice Details</h3>
              <p>
                <strong>Date:</strong> {{invoice_date}}<br>
                <strong>Due Date:</strong> {{due_date}}<br>
                <strong>Currency:</strong> {{currency}}
              </p>
            </div>
          </div>

          <table class="line-items">
            <thead>
              <tr>
                <th>Description</th>
                <th class="text-right">Qty</th>
                <th class="text-right">Unit Price</th>
                <th class="text-right">Amount</th>
              </tr>
            </thead>
            <tbody>
              {{line_items_html}}
            </tbody>
          </table>

          <div class="totals">
            <table class="totals-table">
              <tr>
                <td class="label">Subtotal:</td>
                <td class="value">{{subtotal}} {{currency}}</td>
              </tr>
              <tr>
                <td class="label">Tax:</td>
                <td class="value">{{tax_amount}} {{currency}}</td>
              </tr>
              <tr class="total-row">
                <td class="label">Total:</td>
                <td class="value">{{total}} {{currency}}</td>
              </tr>
            </table>
          </div>

          <div class="due-date-box">
            <strong>Payment Due: {{due_date}}</strong><br>
            {{payment_terms}}
          </div>

          <div class="bank-details">
            <h3>💳 Bank Transfer Details</h3>
            <table>
              <tr>
                <td class="label">Bank:</td>
                <td class="value">{{bank_name}}</td>
              </tr>
              <tr>
                <td class="label">IBAN:</td>
                <td class="value">{{bank_iban}}</td>
              </tr>
              <tr>
                <td class="label">SWIFT/BIC:</td>
                <td class="value">{{bank_swift}}</td>
              </tr>
              <tr>
                <td class="label">Reference:</td>
                <td class="value">{{invoice_number}}</td>
              </tr>
            </table>
          </div>

          <p style="text-align: center;">
            <a href="{{invoice_url}}" class="button">View Invoice Online</a>
          </p>
        </div>

        <div class="footer">
          <div class="company-info">
            <span class="company-name">{{company_name}}</span><br>
            {{company_address}}<br>
            VAT: {{company_vat}}
          </div>
          <p>If you have any questions about this invoice, please contact us.</p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  @doc """
  Returns the text template for billing invoice emails.
  """
  def billing_invoice_text_template do
    """
    =============================================
    INVOICE {{invoice_number}}
    =============================================

    Bill To: {{user_name}}
    Email: {{user_email}}

    Invoice Date: {{invoice_date}}
    Due Date: {{due_date}}
    Currency: {{currency}}

    ---------------------------------------------
    LINE ITEMS
    ---------------------------------------------
    {{line_items_text}}

    ---------------------------------------------
    SUMMARY
    ---------------------------------------------
    Subtotal:    {{subtotal}} {{currency}}
    Tax:         {{tax_amount}} {{currency}}
    ---------------------------------------------
    TOTAL:       {{total}} {{currency}}
    ---------------------------------------------

    PAYMENT DUE: {{due_date}}
    {{payment_terms}}

    ---------------------------------------------
    BANK TRANSFER DETAILS
    ---------------------------------------------
    Bank:        {{bank_name}}
    IBAN:        {{bank_iban}}
    SWIFT/BIC:   {{bank_swift}}
    Reference:   {{invoice_number}}

    ---------------------------------------------
    View invoice online: {{invoice_url}}

    =============================================
    {{company_name}}
    {{company_address}}
    VAT: {{company_vat}}
    =============================================

    If you have any questions about this invoice, please contact us.
    """
  end

  @doc """
  Returns the HTML template for billing receipt emails.
  """
  def billing_receipt_html_template do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Receipt {{receipt_number}}</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; background-color: #f8f9fa; margin: 0; padding: 20px; }
        .container { max-width: 800px; margin: 0 auto; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .header { background: linear-gradient(135deg, #059669 0%, #10b981 100%); color: white; padding: 30px; }
        .header h1 { margin: 0 0 10px 0; font-size: 28px; }
        .header .receipt-number { font-size: 18px; opacity: 0.9; }
        .paid-badge { display: inline-block; background: rgba(255,255,255,0.2); padding: 4px 12px; border-radius: 20px; font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: 1px; margin-top: 10px; }
        .content { padding: 30px; }
        .thank-you-box { background: #d1fae5; border: 1px solid #10b981; border-radius: 8px; padding: 20px; margin-bottom: 30px; text-align: center; }
        .thank-you-box h2 { margin: 0 0 10px 0; color: #059669; font-size: 24px; }
        .thank-you-box p { margin: 0; color: #047857; }
        .receipt-meta { display: flex; justify-content: space-between; margin-bottom: 30px; padding-bottom: 20px; border-bottom: 2px solid #e5e7eb; }
        .receipt-meta .column { flex: 1; }
        .receipt-meta h3 { margin: 0 0 10px 0; color: #6b7280; font-size: 12px; text-transform: uppercase; letter-spacing: 1px; }
        .receipt-meta p { margin: 0; line-height: 1.8; }
        .line-items { width: 100%; border-collapse: collapse; margin: 20px 0; }
        .line-items th { background: #f3f4f6; padding: 12px 15px; text-align: left; font-weight: 600; color: #374151; border-bottom: 2px solid #e5e7eb; }
        .line-items td { padding: 12px 15px; border-bottom: 1px solid #e5e7eb; }
        .line-items .text-right { text-align: right; }
        .line-items .item-name { font-weight: 500; }
        .line-items .item-desc { font-size: 13px; color: #6b7280; }
        .totals { margin-top: 20px; }
        .totals-table { width: 300px; margin-left: auto; }
        .totals-table td { padding: 8px 15px; }
        .totals-table .label { text-align: right; color: #6b7280; }
        .totals-table .value { text-align: right; font-weight: 500; }
        .totals-table .total-row { font-size: 18px; font-weight: 700; border-top: 2px solid #059669; }
        .totals-table .total-row td { padding-top: 15px; color: #059669; }
        .payment-confirmed { background: #ecfdf5; border: 1px solid #10b981; border-radius: 8px; padding: 15px 20px; margin: 20px 0; text-align: center; }
        .payment-confirmed .checkmark { font-size: 32px; margin-bottom: 10px; }
        .payment-confirmed strong { color: #059669; }
        .button { display: inline-block; padding: 14px 28px; background-color: #10b981; color: white; text-decoration: none; border-radius: 6px; font-weight: 600; margin: 20px 0; }
        .button:hover { background-color: #059669; }
        .footer { background: #f8f9fa; padding: 20px 30px; font-size: 13px; color: #6b7280; border-top: 1px solid #e5e7eb; }
        .footer .company-info { margin-bottom: 15px; }
        .footer .company-name { font-weight: 600; color: #374151; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>RECEIPT</h1>
          <div class="receipt-number">{{receipt_number}}</div>
          <div class="paid-badge">PAID</div>
        </div>

        <div class="content">
          <div class="thank-you-box">
            <h2>Thank You for Your Payment!</h2>
            <p>Your payment has been successfully processed.</p>
          </div>

          <div class="receipt-meta">
            <div class="column">
              <h3>Received From</h3>
              <p>
                <strong>{{user_name}}</strong><br>
                {{user_email}}
              </p>
            </div>
            <div class="column" style="text-align: right;">
              <h3>Receipt Details</h3>
              <p>
                <strong>Payment Date:</strong> {{payment_date}}<br>
                <strong>Invoice:</strong> {{invoice_number}}<br>
                <strong>Currency:</strong> {{currency}}
              </p>
            </div>
          </div>

          <table class="line-items">
            <thead>
              <tr>
                <th>Description</th>
                <th class="text-right">Qty</th>
                <th class="text-right">Unit Price</th>
                <th class="text-right">Amount</th>
              </tr>
            </thead>
            <tbody>
              {{line_items_html}}
            </tbody>
          </table>

          <div class="totals">
            <table class="totals-table">
              <tr>
                <td class="label">Subtotal:</td>
                <td class="value">{{subtotal}} {{currency}}</td>
              </tr>
              <tr>
                <td class="label">Tax:</td>
                <td class="value">{{tax_amount}} {{currency}}</td>
              </tr>
              <tr class="total-row">
                <td class="label">Total Paid:</td>
                <td class="value">{{paid_amount}} {{currency}}</td>
              </tr>
            </table>
          </div>

          <div class="payment-confirmed">
            <div class="checkmark">✓</div>
            <strong>Payment Confirmed on {{payment_date}}</strong>
          </div>

          <p style="text-align: center;">
            <a href="{{receipt_url}}" class="button">View Receipt Online</a>
          </p>
        </div>

        <div class="footer">
          <div class="company-info">
            <span class="company-name">{{company_name}}</span><br>
            {{company_address}}<br>
            VAT: {{company_vat}}
          </div>
          <p>Thank you for your business. If you have any questions, please contact us.</p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  @doc """
  Returns the text template for billing receipt emails.
  """
  def billing_receipt_text_template do
    """
    =============================================
    RECEIPT {{receipt_number}}
    =============================================
    STATUS: PAID

    Thank you for your payment!
    Your payment has been successfully processed.

    ---------------------------------------------
    RECEIVED FROM
    ---------------------------------------------
    Name: {{user_name}}
    Email: {{user_email}}

    Payment Date: {{payment_date}}
    Invoice: {{invoice_number}}
    Currency: {{currency}}

    ---------------------------------------------
    LINE ITEMS
    ---------------------------------------------
    {{line_items_text}}

    ---------------------------------------------
    SUMMARY
    ---------------------------------------------
    Subtotal:    {{subtotal}} {{currency}}
    Tax:         {{tax_amount}} {{currency}}
    ---------------------------------------------
    TOTAL PAID:  {{paid_amount}} {{currency}}
    ---------------------------------------------

    PAYMENT CONFIRMED: {{payment_date}}

    ---------------------------------------------
    View receipt online: {{receipt_url}}

    =============================================
    {{company_name}}
    {{company_address}}
    VAT: {{company_vat}}
    =============================================

    Thank you for your business.
    If you have any questions, please contact us.
    """
  end

  @doc """
  Returns the HTML template for billing credit note emails.

  IMPORTANT: In a credit note, the roles are reversed compared to invoice:
  - The company (seller) is now the PAYER (issuing the refund)
  - The customer is now the PAYEE (receiving the refund)
  """
  def billing_credit_note_html_template do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Credit Note {{credit_note_number}}</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; background-color: #f8f9fa; margin: 0; padding: 20px; }
        .container { max-width: 800px; margin: 0 auto; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .header { background: linear-gradient(135deg, #d97706 0%, #f59e0b 100%); color: white; padding: 30px; }
        .header h1 { margin: 0 0 10px 0; font-size: 28px; }
        .header .credit-note-number { font-size: 18px; opacity: 0.9; }
        .refund-badge { display: inline-block; background: rgba(255,255,255,0.2); padding: 4px 12px; border-radius: 20px; font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: 1px; margin-top: 10px; }
        .content { padding: 30px; }
        .refund-box { background: #fef3c7; border: 1px solid #f59e0b; border-radius: 8px; padding: 20px; margin-bottom: 30px; text-align: center; }
        .refund-box h2 { margin: 0 0 10px 0; color: #92400e; font-size: 24px; }
        .refund-box p { margin: 0; color: #b45309; }
        .refund-box .amount { font-size: 32px; font-weight: 700; color: #92400e; margin-top: 10px; }
        .credit-note-meta { display: flex; justify-content: space-between; margin-bottom: 30px; padding-bottom: 20px; border-bottom: 2px solid #e5e7eb; }
        .credit-note-meta .column { flex: 1; }
        .credit-note-meta h3 { margin: 0 0 10px 0; color: #6b7280; font-size: 12px; text-transform: uppercase; letter-spacing: 1px; }
        .credit-note-meta p { margin: 0; line-height: 1.8; }
        .details-box { background: #f9fafb; border-radius: 8px; padding: 20px; margin-bottom: 20px; }
        .details-box h4 { margin: 0 0 15px 0; color: #374151; font-size: 14px; }
        .details-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 15px; }
        .details-grid .detail { }
        .details-grid .detail .label { font-size: 12px; color: #6b7280; text-transform: uppercase; letter-spacing: 0.5px; }
        .details-grid .detail .value { font-weight: 600; color: #1f2937; margin-top: 4px; }
        .reason-box { background: #fffbeb; border: 1px solid #fde68a; border-radius: 8px; padding: 15px 20px; margin: 20px 0; }
        .reason-box h4 { margin: 0 0 8px 0; color: #92400e; font-size: 13px; }
        .reason-box p { margin: 0; color: #78350f; }
        .button { display: inline-block; padding: 14px 28px; background-color: #f59e0b; color: white; text-decoration: none; border-radius: 6px; font-weight: 600; margin: 20px 0; }
        .button:hover { background-color: #d97706; }
        .footer { background: #f8f9fa; padding: 20px 30px; font-size: 13px; color: #6b7280; border-top: 1px solid #e5e7eb; }
        .footer .company-info { margin-bottom: 15px; }
        .footer .company-name { font-weight: 600; color: #374151; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>CREDIT NOTE</h1>
          <div class="credit-note-number">{{credit_note_number}}</div>
          <div class="refund-badge">REFUND ISSUED</div>
        </div>

        <div class="content">
          <div class="refund-box">
            <h2>Refund Issued</h2>
            <p>A refund has been processed for your account.</p>
            <div class="amount">{{refund_amount}} {{currency}}</div>
          </div>

          <div class="credit-note-meta">
            <div class="column">
              <h3>Issued By (Payer)</h3>
              <p>
                <strong>{{company_name}}</strong><br>
                {{company_address}}<br>
                VAT: {{company_vat}}
              </p>
            </div>
            <div class="column">
              <h3>Issued To (Payee)</h3>
              <p>
                <strong>{{user_name}}</strong><br>
                {{user_email}}
              </p>
            </div>
            <div class="column" style="text-align: right;">
              <h3>Credit Note Details</h3>
              <p>
                <strong>Date:</strong> {{refund_date}}<br>
                <strong>Invoice:</strong> {{invoice_number}}<br>
                <strong>Currency:</strong> {{currency}}
              </p>
            </div>
          </div>

          <div class="details-box">
            <h4>Refund Details</h4>
            <div class="details-grid">
              <div class="detail">
                <div class="label">Refund Amount</div>
                <div class="value">{{refund_amount}} {{currency}}</div>
              </div>
              <div class="detail">
                <div class="label">Refund Date</div>
                <div class="value">{{refund_date}}</div>
              </div>
              <div class="detail">
                <div class="label">Transaction Reference</div>
                <div class="value">{{transaction_number}}</div>
              </div>
              <div class="detail">
                <div class="label">Original Invoice</div>
                <div class="value">{{invoice_number}}</div>
              </div>
            </div>
          </div>

          <div class="reason-box">
            <h4>Reason for Refund</h4>
            <p>{{refund_reason}}</p>
          </div>

          <p style="text-align: center;">
            <a href="{{credit_note_url}}" class="button">View Credit Note Online</a>
          </p>

          <p style="text-align: center; font-size: 13px; color: #6b7280;">
            The refund will be processed to your original payment method.<br>
            Please allow 5-10 business days for the refund to appear in your account.
          </p>
        </div>

        <div class="footer">
          <div class="company-info">
            <span class="company-name">{{company_name}}</span><br>
            {{company_address}}<br>
            VAT: {{company_vat}}
          </div>
          <p>If you have any questions about this refund, please contact us.</p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  @doc """
  Returns the text template for billing credit note emails.
  """
  def billing_credit_note_text_template do
    """
    =============================================
    CREDIT NOTE {{credit_note_number}}
    =============================================
    STATUS: REFUND ISSUED

    A refund has been processed for your account.

    REFUND AMOUNT: {{refund_amount}} {{currency}}

    ---------------------------------------------
    ISSUED BY (PAYER)
    ---------------------------------------------
    {{company_name}}
    {{company_address}}
    VAT: {{company_vat}}

    ---------------------------------------------
    ISSUED TO (PAYEE)
    ---------------------------------------------
    Name: {{user_name}}
    Email: {{user_email}}

    ---------------------------------------------
    REFUND DETAILS
    ---------------------------------------------
    Credit Note #:     {{credit_note_number}}
    Refund Date:       {{refund_date}}
    Refund Amount:     {{refund_amount}} {{currency}}
    Original Invoice:  {{invoice_number}}
    Transaction #:     {{transaction_number}}

    ---------------------------------------------
    REASON FOR REFUND
    ---------------------------------------------
    {{refund_reason}}

    ---------------------------------------------
    View credit note online: {{credit_note_url}}

    The refund will be processed to your original payment method.
    Please allow 5-10 business days for the refund to appear in your account.

    =============================================
    {{company_name}}
    {{company_address}}
    VAT: {{company_vat}}
    =============================================

    If you have any questions about this refund, please contact us.
    """
  end

  @doc """
  Returns the HTML template for billing payment confirmation emails.
  """
  def billing_payment_confirmation_html_template do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Payment Confirmation {{confirmation_number}}</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; background-color: #f8f9fa; margin: 0; padding: 20px; }
        .container { max-width: 800px; margin: 0 auto; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .header { background: linear-gradient(135deg, #047857 0%, #059669 100%); color: white; padding: 30px; }
        .header h1 { margin: 0 0 10px 0; font-size: 28px; }
        .header .confirmation-number { font-size: 18px; opacity: 0.9; }
        .status-badge { display: inline-block; background: rgba(255,255,255,0.2); padding: 4px 12px; border-radius: 20px; font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: 1px; margin-top: 10px; }
        .content { padding: 30px; }
        .payment-box { background: #d1fae5; border: 1px solid #059669; border-radius: 8px; padding: 20px; margin-bottom: 30px; text-align: center; }
        .payment-box h2 { margin: 0 0 10px 0; color: #047857; font-size: 24px; }
        .payment-box p { margin: 0; color: #059669; }
        .payment-box .amount { font-size: 32px; font-weight: 700; color: #047857; margin-top: 10px; }
        .balance-section { display: flex; gap: 15px; margin-bottom: 30px; }
        .balance-box { flex: 1; padding: 15px; border-radius: 8px; text-align: center; }
        .balance-box.total { background: #f3f4f6; border: 1px solid #e5e7eb; }
        .balance-box.paid { background: #d1fae5; border: 1px solid #059669; }
        .balance-box.remaining { background: #fef3c7; border: 1px solid #f59e0b; }
        .balance-box.remaining.zero { background: #d1fae5; border-color: #059669; }
        .balance-box .label { font-size: 12px; color: #6b7280; text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 5px; }
        .balance-box .value { font-size: 20px; font-weight: 700; }
        .balance-box.total .value { color: #374151; }
        .balance-box.paid .value { color: #047857; }
        .balance-box.remaining .value { color: #b45309; }
        .balance-box.remaining.zero .value { color: #047857; }
        .details-box { background: #f9fafb; border-radius: 8px; padding: 20px; margin-bottom: 20px; }
        .details-box h4 { margin: 0 0 15px 0; color: #374151; font-size: 14px; }
        .details-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 15px; }
        .details-grid .detail .label { font-size: 12px; color: #6b7280; text-transform: uppercase; letter-spacing: 0.5px; }
        .details-grid .detail .value { font-weight: 600; color: #1f2937; margin-top: 4px; }
        .btn { display: inline-block; padding: 12px 24px; background: #059669; color: white; text-decoration: none; border-radius: 6px; font-weight: 600; margin-top: 20px; }
        .footer { background: #f9fafb; padding: 20px 30px; border-top: 1px solid #e5e7eb; }
        .footer-text { font-size: 12px; color: #6b7280; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>Payment Confirmation</h1>
          <div class="confirmation-number">{{confirmation_number}}</div>
          <div class="status-badge">Payment Received</div>
        </div>

        <div class="content">
          <p>Dear {{user_name}},</p>
          <p>Thank you for your payment. We have received the following payment:</p>

          <div class="payment-box">
            <h2>Payment Received</h2>
            <p>{{payment_date}}</p>
            <div class="amount">{{payment_amount}} {{currency}}</div>
          </div>

          <div class="balance-section">
            <div class="balance-box total">
              <div class="label">Invoice Total</div>
              <div class="value">{{invoice_total}} {{currency}}</div>
            </div>
            <div class="balance-box paid">
              <div class="label">Total Paid</div>
              <div class="value">{{total_paid}} {{currency}}</div>
            </div>
            <div class="balance-box remaining">
              <div class="label">Remaining</div>
              <div class="value">{{remaining_balance}} {{currency}}</div>
            </div>
          </div>

          <div class="details-box">
            <h4>Payment Details</h4>
            <div class="details-grid">
              <div class="detail">
                <div class="label">Confirmation #</div>
                <div class="value">{{confirmation_number}}</div>
              </div>
              <div class="detail">
                <div class="label">Invoice #</div>
                <div class="value">{{invoice_number}}</div>
              </div>
              <div class="detail">
                <div class="label">Payment Method</div>
                <div class="value">{{payment_method}}</div>
              </div>
              <div class="detail">
                <div class="label">Transaction #</div>
                <div class="value">{{transaction_number}}</div>
              </div>
            </div>
          </div>

          <p style="text-align: center;">
            <a href="{{payment_url}}" class="btn">View Payment Confirmation</a>
          </p>
        </div>

        <div class="footer">
          <p class="footer-text">
            {{company_name}}<br>
            {{company_address}}
          </p>
          <p class="footer-text">Thank you for your business.</p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  @doc """
  Returns the text template for billing payment confirmation emails.
  """
  def billing_payment_confirmation_text_template do
    """
    =============================================
    PAYMENT CONFIRMATION {{confirmation_number}}
    =============================================
    STATUS: PAYMENT RECEIVED

    Thank you for your payment.

    PAYMENT AMOUNT: {{payment_amount}} {{currency}}

    ---------------------------------------------
    PAYMENT DETAILS
    ---------------------------------------------
    Confirmation #:    {{confirmation_number}}
    Invoice #:         {{invoice_number}}
    Payment Date:      {{payment_date}}
    Payment Method:    {{payment_method}}
    Transaction #:     {{transaction_number}}

    ---------------------------------------------
    BALANCE SUMMARY
    ---------------------------------------------
    Invoice Total:     {{invoice_total}} {{currency}}
    Total Paid:        {{total_paid}} {{currency}}
    Remaining:         {{remaining_balance}} {{currency}}

    ---------------------------------------------
    View payment confirmation online: {{payment_url}}

    =============================================
    {{company_name}}
    {{company_address}}
    =============================================

    Thank you for your business. If you have any questions, please contact us.
    """
  end
end
