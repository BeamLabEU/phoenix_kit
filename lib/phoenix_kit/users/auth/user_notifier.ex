defmodule PhoenixKit.Users.Auth.UserNotifier do
  @moduledoc """
  User notification system for PhoenixKit authentication workflows.

  This module handles email delivery for user authentication and account management workflows,
  including account confirmation, password reset, and email change notifications.

  ## Email Types

  - **Confirmation instructions**: Sent during user registration
  - **Password reset instructions**: Sent when user requests password reset
  - **Email update instructions**: Sent when user changes their email address

  ## Configuration

  Configure your mailer in your application config:

      config :phoenix_kit, PhoenixKit.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        # ... other adapter configuration

  ## Customization

  Override this module in your application to customize email templates
  and delivery behavior while maintaining the same function signatures.
  """
  import Swoosh.Email

  alias PhoenixKit.Email.Provider
  alias PhoenixKit.Mailer

  # Delivers the email using the appropriate mailer.
  # Uses the configured parent application mailer if available,
  # otherwise falls back to PhoenixKit's built-in mailer.
  defp deliver(recipient, subject, text_body, html_body) do
    from_email = get_from_email()
    from_name = get_from_name()

    email =
      new()
      |> to(recipient)
      |> from({from_name, from_email})
      |> subject(subject)
      |> text_body(text_body)
      |> html_body(html_body)

    with {:ok, _metadata} <-
           Mailer.deliver_email(email,
             user_uuid: nil,
             template_name: "user_notification",
             campaign_id: "authentication"
           ) do
      {:ok, email}
    end
  end

  # Get the from email address from configuration or use a default
  # Priority: Settings Database > Config file > Default
  defp get_from_email do
    # Priority 1: Settings Database (runtime)
    case PhoenixKit.Settings.get_setting("from_email") do
      nil ->
        # Priority 2: Config file (compile-time, fallback)
        case PhoenixKit.Config.get(:from_email) do
          {:ok, email} -> email
          # Priority 3: Default
          _ -> "noreply@localhost"
        end

      email ->
        email
    end
  end

  # Get the from name from configuration or use a default
  # Priority: Settings Database > Config file > Default
  defp get_from_name do
    # Priority 1: Settings Database (runtime)
    case PhoenixKit.Settings.get_setting("from_name") do
      nil ->
        # Priority 2: Config file (compile-time, fallback)
        case PhoenixKit.Config.get(:from_name) do
          {:ok, name} -> name
          # Priority 3: Default
          _ -> "PhoenixKit"
        end

      name ->
        name
    end
  end

  @doc """
  Deliver instructions to confirm account.

  Uses the 'register' template from the database if available,
  falls back to hardcoded template if not found.
  """
  def deliver_confirmation_instructions(user, url) do
    # Variables for template substitution
    template_variables = %{
      "user_email" => user.email,
      "confirmation_url" => url
    }

    # Try to get template from database, fallback to text-only
    {subject, html_body, text_body, db_template} =
      case Provider.current().get_active_template_by_name("register") do
        nil ->
          fallback_text = """
          Hi #{user.email},

          You can confirm your account by visiting the URL below:

          #{url}

          If you didn't create an account with us, please ignore this.
          """

          {"Confirm your account", nil, fallback_text, nil}

        template ->
          rendered = Provider.current().render_template(template, template_variables)
          {rendered.subject, rendered.html_body, rendered.text_body, template}
      end

    if db_template, do: Provider.current().track_usage(db_template)

    deliver(user.email, subject, text_body, html_body)
  end

  @doc """
  Deliver instructions to reset a user password.

  Uses the 'reset_password' template from the database if available,
  falls back to hardcoded template if not found.
  """
  def deliver_reset_password_instructions(user, url) do
    # Variables for template substitution
    template_variables = %{
      "user_email" => user.email,
      "reset_url" => url
    }

    # Try to get template from database, fallback to text-only
    {subject, html_body, text_body, db_template} =
      case Provider.current().get_active_template_by_name("reset_password") do
        nil ->
          fallback_text = """
          Hi #{user.email},

          You can reset your password by visiting the URL below:

          #{url}

          If you didn't request this change, please ignore this.
          """

          {"Reset your password", nil, fallback_text, nil}

        template ->
          rendered = Provider.current().render_template(template, template_variables)
          {rendered.subject, rendered.html_body, rendered.text_body, template}
      end

    if db_template, do: Provider.current().track_usage(db_template)

    deliver(user.email, subject, text_body, html_body)
  end

  @doc """
  Deliver instructions to update a user email.

  Uses the 'update_email' template from the database if available,
  falls back to hardcoded template if not found.
  """
  def deliver_update_email_instructions(user, url) do
    # Variables for template substitution
    template_variables = %{
      "user_email" => user.email,
      "update_url" => url
    }

    # Try to get template from database, fallback to text-only
    {subject, html_body, text_body, db_template} =
      case Provider.current().get_active_template_by_name("update_email") do
        nil ->
          fallback_text = """
          Hi #{user.email},

          You can change your email by visiting the URL below:

          #{url}

          If you didn't request this change, please ignore this.
          """

          {"Confirm your email change", nil, fallback_text, nil}

        template ->
          rendered = Provider.current().render_template(template, template_variables)
          {rendered.subject, rendered.html_body, rendered.text_body, template}
      end

    if db_template, do: Provider.current().track_usage(db_template)

    deliver(user.email, subject, text_body, html_body)
  end

  @doc """
  Deliver magic link registration instructions.

  Uses the 'magic_link_registration' template from the database if available,
  falls back to hardcoded template if not found.
  """
  def deliver_magic_link_registration(user_or_email, url) do
    # Handle both user struct and plain email string
    email =
      case user_or_email do
        %{email: email} -> email
        email when is_binary(email) -> email
      end

    # Variables for template substitution
    template_variables = %{
      "user_email" => email,
      "registration_url" => url
    }

    # Try to get template from database, fallback to text-only
    {subject, html_body, text_body, db_template} =
      case Provider.current().get_active_template_by_name("magic_link_registration") do
        nil ->
          fallback_text = """
          Hi #{email},

          Welcome! To complete your registration, please click the link below:

          #{url}

          This link will expire in 30 minutes for your security.

          If you didn't request this registration, please ignore this email.
          """

          {"Complete Your Registration", nil, fallback_text, nil}

        template ->
          rendered = Provider.current().render_template(template, template_variables)
          {rendered.subject, rendered.html_body, rendered.text_body, template}
      end

    if db_template, do: Provider.current().track_usage(db_template)

    deliver(email, subject, text_body, html_body)
  end
end
