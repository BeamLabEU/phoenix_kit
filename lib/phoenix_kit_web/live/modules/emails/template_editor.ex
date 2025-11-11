defmodule PhoenixKitWeb.Live.Modules.Emails.TemplateEditor do
  @moduledoc """
  LiveView for creating and editing email templates in PhoenixKit admin panel.

  Provides a comprehensive template editor with live preview, variable management,
  test sending functionality, and template validation.

  ## Features

  - **Live Preview**: Real-time HTML and text preview with variable substitution
  - **Variable Management**: Define and validate template variables
  - **Template Validation**: Real-time validation of template content
  - **Test Send**: Send test emails using the template
  - **Version Control**: Track template versions and changes
  - **Syntax Highlighting**: Basic HTML syntax awareness

  ## Routes

  - `/admin/modules/emails/templates/new` - Create new template
  - `/admin/modules/emails/templates/:id/edit` - Edit existing template

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Emails.Template
  alias PhoenixKit.Emails.Templates
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.Core.Icons, only: [icon_arrow_left: 1]

  ## --- Lifecycle Callbacks ---

  @impl true
  def mount(_params, _session, socket) do
    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    socket =
      socket
      |> assign(:project_title, project_title)
      |> assign(:template, nil)
      |> assign(:mode, :new)
      |> assign(:loading, false)
      |> assign(:saving, false)
      |> assign(:changeset, Template.changeset(%Template{}, %{}))
      |> assign(:preview_mode, "html")
      |> assign(:show_test_modal, false)
      |> assign(:test_sending, false)
      |> assign(:test_form, %{recipient: "", sample_variables: %{}, errors: %{}})
      |> assign(:extracted_variables, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    case Templates.get_template(String.to_integer(id)) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Template not found")
         |> push_navigate(to: Routes.path("/admin/modules/emails/templates"))}

      template ->
        changeset = Template.changeset(template, %{})
        extracted_variables = Template.extract_variables(template)

        socket =
          socket
          |> assign(:page_title, "Edit Template: #{template.display_name}")
          |> assign(:template, template)
          |> assign(:mode, :edit)
          |> assign(:changeset, changeset)
          |> assign(:extracted_variables, extracted_variables)

        {:noreply, socket}
    end
  end

  def handle_params(params, _url, socket) do
    # New template mode
    initial_attrs = %{
      name: params["name"] || "",
      display_name: params["display_name"] || "",
      category: params["category"] || "transactional",
      subject: "",
      html_body: default_html_template(),
      text_body: default_text_template(),
      status: "draft",
      variables: %{}
    }

    changeset = Template.changeset(%Template{}, initial_attrs)

    socket =
      socket
      |> assign(:page_title, "Create New Template")
      |> assign(:template, nil)
      |> assign(:mode, :new)
      |> assign(:changeset, changeset)
      |> assign(:extracted_variables, [])

    {:noreply, socket}
  end

  ## --- Event Handlers ---

  @impl true
  def handle_event("validate", %{"email_template" => template_params}, socket) do
    template = socket.assigns.template || %Template{}

    # Extract variables from current content
    temp_template = %Template{
      subject: template_params["subject"] || "",
      html_body: template_params["html_body"] || "",
      text_body: template_params["text_body"] || ""
    }

    extracted_variables = Template.extract_variables(temp_template)

    # Auto-add extracted variables with smart descriptions
    current_variables = template_params["variables"] || %{}

    # Convert string keys to ensure consistency
    current_variables =
      if is_map(current_variables) do
        current_variables
      else
        %{}
      end

    # Add any new extracted variables with smart descriptions
    updated_variables =
      Enum.reduce(extracted_variables, current_variables, fn var, acc ->
        if Map.has_key?(acc, var) do
          acc
        else
          Map.put(acc, var, smart_description_for_variable(var))
        end
      end)

    # Merge updated variables into template params
    template_params_with_vars = Map.put(template_params, "variables", updated_variables)

    changeset = Template.changeset(template, template_params_with_vars)

    socket =
      socket
      |> assign(:changeset, %{changeset | action: :validate})
      |> assign(:extracted_variables, extracted_variables)

    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"email_template" => template_params, "save_as" => save_as}, socket) do
    socket = assign(socket, :saving, true)

    # Extract variables and auto-add them before saving
    temp_template = %Template{
      subject: template_params["subject"] || "",
      html_body: template_params["html_body"] || "",
      text_body: template_params["text_body"] || ""
    }

    extracted_variables = Template.extract_variables(temp_template)

    # Auto-add extracted variables with smart descriptions
    current_variables = template_params["variables"] || %{}

    current_variables =
      if is_map(current_variables) do
        current_variables
      else
        %{}
      end

    updated_variables =
      Enum.reduce(extracted_variables, current_variables, fn var, acc ->
        if Map.has_key?(acc, var) do
          acc
        else
          Map.put(acc, var, smart_description_for_variable(var))
        end
      end)

    template_params_with_vars = Map.put(template_params, "variables", updated_variables)

    # Override status if saving as draft
    template_params_final =
      if save_as == "draft" do
        Map.put(template_params_with_vars, "status", "draft")
      else
        template_params_with_vars
      end

    case socket.assigns.mode do
      :new ->
        create_template(socket, template_params_final)

      :edit ->
        update_template(socket, template_params_final)
    end
  end

  @impl true
  def handle_event("save", %{"email_template" => template_params}, socket) do
    # Default save without save_as parameter
    handle_event("save", %{"email_template" => template_params, "save_as" => "active"}, socket)
  end

  @impl true
  def handle_event("switch_preview", %{"mode" => mode}, socket) when mode in ["html", "text"] do
    {:noreply, assign(socket, :preview_mode, mode)}
  end

  @impl true
  def handle_event("show_test_modal", _params, socket) do
    # Generate sample variables based on extracted variables
    sample_variables = generate_sample_variables(socket.assigns.extracted_variables)

    test_form = %{
      recipient: "",
      sample_variables: sample_variables,
      errors: %{}
    }

    {:noreply,
     socket
     |> assign(:show_test_modal, true)
     |> assign(:test_form, test_form)}
  end

  @impl true
  def handle_event("hide_test_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_test_modal, false)
     |> assign(:test_sending, false)
     |> assign(:test_form, %{recipient: "", sample_variables: %{}, errors: %{}})}
  end

  @impl true
  def handle_event("validate_test", params, socket) do
    test_params = params["test"] || %{}
    errors = validate_test_form(test_params)

    sample_variables =
      case test_params["sample_variables"] do
        nil -> socket.assigns.test_form.sample_variables
        vars -> vars
      end

    test_form = %{
      recipient: test_params["recipient"] || "",
      sample_variables: sample_variables,
      errors: errors
    }

    {:noreply, assign(socket, :test_form, test_form)}
  end

  @impl true
  def handle_event("send_test", params, socket) do
    test_params = params["test"] || %{}
    errors = validate_test_form(test_params)

    if map_size(errors) == 0 do
      socket = assign(socket, :test_sending, true)

      # Get current template data from changeset
      changeset_data = Ecto.Changeset.apply_changes(socket.assigns.changeset)
      sample_variables = test_params["sample_variables"] || %{}

      # Send test email
      send(self(), {:send_test_email, test_params["recipient"], changeset_data, sample_variables})

      {:noreply, socket}
    else
      test_form = %{
        recipient: test_params["recipient"] || "",
        sample_variables: test_params["sample_variables"] || %{},
        errors: errors
      }

      {:noreply, assign(socket, :test_form, test_form)}
    end
  end

  @impl true
  def handle_event(
        "update_variable_description",
        %{"name" => name, "value" => description},
        socket
      ) do
    changeset = socket.assigns.changeset

    current_variables = Ecto.Changeset.get_field(changeset, :variables) || %{}
    updated_variables = Map.put(current_variables, name, description)

    updated_changeset = Ecto.Changeset.put_change(changeset, :variables, updated_variables)

    {:noreply, assign(socket, :changeset, updated_changeset)}
  end

  @impl true
  def handle_event("remove_variable", %{"name" => name}, socket) do
    changeset = socket.assigns.changeset

    current_variables = Ecto.Changeset.get_field(changeset, :variables) || %{}
    updated_variables = Map.delete(current_variables, name)

    updated_changeset = Ecto.Changeset.put_change(changeset, :variables, updated_variables)

    {:noreply, assign(socket, :changeset, updated_changeset)}
  end

  ## --- Info Handlers ---

  @impl true
  def handle_info({:send_test_email, recipient, template_data, sample_variables}, socket) do
    # Create a temporary template for testing
    temp_template = %Template{
      name: template_data.name || "test_template",
      subject: template_data.subject || "",
      html_body: template_data.html_body || "",
      text_body: template_data.text_body || ""
    }

    # Render template with sample variables
    rendered = Templates.render_template(temp_template, sample_variables)

    # Use PhoenixKit.Mailer to send test email
    email =
      Swoosh.Email.new()
      |> Swoosh.Email.to(recipient)
      |> Swoosh.Email.from({"PhoenixKit Test", get_from_email()})
      |> Swoosh.Email.subject("[TEST] #{rendered.subject}")
      |> Swoosh.Email.html_body(rendered.html_body)
      |> Swoosh.Email.text_body(rendered.text_body)

    case PhoenixKit.Mailer.deliver_email(email,
           template_name: temp_template.name,
           campaign_id: "template_test"
         ) do
      {:ok, _email} ->
        {:noreply,
         socket
         |> assign(:test_sending, false)
         |> assign(:show_test_modal, false)
         |> put_flash(:info, "Test email sent successfully to #{recipient}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:test_sending, false)
         |> put_flash(:error, "Failed to send test email: #{inspect(reason)}")}
    end
  rescue
    error ->
      {:noreply,
       socket
       |> assign(:test_sending, false)
       |> put_flash(:error, "Error sending test email: #{Exception.message(error)}")}
  end

  ## --- Private Helper Functions ---

  defp create_template(socket, template_params) do
    case Templates.create_template(template_params) do
      {:ok, template} ->
        {:noreply,
         socket
         |> assign(:saving, false)
         |> put_flash(:info, "Template '#{template.name}' created successfully")
         |> push_navigate(to: Routes.path("/admin/modules/emails/templates"))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:saving, false)
         |> assign(:changeset, changeset)}
    end
  end

  defp update_template(socket, template_params) do
    case Templates.update_template(socket.assigns.template, template_params) do
      {:ok, template} ->
        {:noreply,
         socket
         |> assign(:saving, false)
         |> assign(:template, template)
         |> put_flash(
           :info,
           "Template '#{template.name}' updated successfully (v#{template.version})"
         )}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:saving, false)
         |> assign(:changeset, changeset)}
    end
  end

  defp smart_description_for_variable(variable) do
    descriptions = %{
      "user_name" => "User's display name",
      "user_email" => "User's email address",
      "email" => "User's email address",
      "url" => "Action URL or link",
      "confirmation_url" => "Email confirmation link",
      "reset_url" => "Password reset link",
      "magic_link_url" => "Magic link authentication URL",
      "update_url" => "Profile update URL",
      "timestamp" => "Current timestamp",
      "app_name" => "Application name",
      "company_name" => "Company or organization name",
      "support_email" => "Support contact email",
      "first_name" => "User's first name",
      "last_name" => "User's last name",
      "username" => "User's username",
      "token" => "Verification or authentication token",
      "code" => "Verification code",
      "expiry" => "Expiration date/time",
      "subject" => "Email subject line"
    }

    Map.get(descriptions, variable, "Custom variable: #{variable}")
  end

  defp generate_sample_variables(variables) do
    Enum.into(variables, %{}, fn variable ->
      {variable, get_sample_value_for_variable(variable)}
    end)
  end

  defp get_sample_value_for_variable(variable) do
    sample_data = %{
      "user_name" => "John Doe",
      "user_email" => "john@example.com",
      "email" => "john@example.com",
      "url" => "https://example.com/action",
      "confirmation_url" => "https://example.com/confirm",
      "reset_url" => "https://example.com/reset",
      "magic_link_url" => "https://example.com/magic",
      "update_url" => "https://example.com/update",
      "timestamp" => DateTime.utc_now() |> DateTime.to_string(),
      "app_name" => "PhoenixKit",
      "company_name" => "Your Company",
      "support_email" => "support@example.com"
    }

    Map.get(sample_data, variable, "Sample #{variable}")
  end

  defp validate_test_form(params) do
    errors = %{}

    # Validate recipient email
    errors =
      case String.trim(params["recipient"] || "") do
        "" ->
          Map.put(errors, :recipient, "Email address is required")

        email ->
          if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email) do
            errors
          else
            Map.put(errors, :recipient, "Please enter a valid email address")
          end
      end

    errors
  end

  defp get_from_email do
    case PhoenixKit.Config.get(:from_email) do
      {:ok, email} -> email
      :not_found -> "noreply@localhost"
    end
  end

  defp default_html_template do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>{{subject}}</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; }
        .header { text-align: center; margin-bottom: 30px; }
        .button { display: inline-block; padding: 12px 24px; background-color: #3b82f6; color: white; text-decoration: none; border-radius: 6px; font-weight: 500; }
        .button:hover { background-color: #2563eb; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #e5e7eb; font-size: 14px; color: #6b7280; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>Your email title here</h1>
        </div>

        <p>Hello {{user_name}},</p>

        <p>Your email content goes here...</p>

        <p style="text-align: center; margin: 30px 0;">
          <a href="{{url}}" class="button">Call to Action</a>
        </p>

        <div class="footer">
          <p>Thank you for using our service!</p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  defp default_text_template do
    """
    Hello {{user_name}},

    Your email content goes here...

    {{url}}

    Thank you for using our service!
    """
  end
end
