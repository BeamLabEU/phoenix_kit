defmodule PhoenixKit.Mailer do
  @moduledoc """
  Mailer module for PhoenixKit emails.

  This module handles sending emails such as
  confirmation emails, password reset emails, magic link emails, etc.

  It can work in two modes:
  1. **Built-in mode**: Uses PhoenixKit's own Swoosh mailer (default)
  2. **Delegation mode**: Uses the parent application's mailer when configured

  ## Configuration

  To use your application's mailer instead of PhoenixKit's built-in one:

      config :phoenix_kit,
        mailer: MyApp.Mailer

  When delegation is configured, all emails will be sent through your application's
  mailer, allowing you to use a single mailer configuration across your entire application.
  """

  use Swoosh.Mailer, otp_app: :phoenix_kit

  import Swoosh.Email

  alias PhoenixKit.Email.Provider
  alias PhoenixKit.Users.Auth.User

  require Logger

  @doc """
  Gets the mailer module to use for sending emails.

  Returns the configured parent application mailer if set,
  otherwise returns the built-in PhoenixKit.Mailer.

  ## Examples

      iex> PhoenixKit.Mailer.get_mailer()
      MyApp.Mailer  # if configured

      iex> PhoenixKit.Mailer.get_mailer()
      PhoenixKit.Mailer  # default
  """
  def get_mailer do
    PhoenixKit.Config.get(:mailer, __MODULE__)
  end

  @doc """
  Sends an email using a template from the database.

  This is the main function for sending emails using PhoenixKit's template system.
  It automatically:
  - Loads the template by name
  - Renders it with provided variables
  - Tracks template usage
  - Sends the email with tracking
  - Logs to EmailSystem

  ## Parameters

  - `template_name` - Name of the template in the database (e.g., "welcome_email")
  - `recipient` - Email address (string) or {name, email} tuple
  - `variables` - Map of variables to substitute in the template
  - `opts` - Additional options:
    - `:user_uuid` - Associate email with a user (for tracking)
    - `:campaign_id` - Campaign identifier (for analytics)
    - `:from` - Override from address (default: configured from_email)
    - `:reply_to` - Reply-to address
    - `:metadata` - Additional metadata map for tracking

  ## Returns

  - `{:ok, email}` - Email sent successfully
  - `{:error, :template_not_found}` - Template doesn't exist
  - `{:error, :template_inactive}` - Template is not active
  - `{:error, reason}` - Other error

  ## Examples

      # Simple welcome email
      PhoenixKit.Mailer.send_from_template(
        "welcome_email",
        "user@example.com",
        %{"user_name" => "John", "url" => "https://app.com"}
      )

      # With user tracking
      PhoenixKit.Mailer.send_from_template(
        "password_reset",
        {"Jane Doe", "jane@example.com"},
        %{"reset_url" => "https://app.com/reset/token123"},
        user_uuid: user.uuid,
        campaign_id: "password_recovery"
      )

      # With metadata
      PhoenixKit.Mailer.send_from_template(
        "order_confirmation",
        customer.email,
        %{"order_id" => "12345", "total" => "$99.99"},
        user_uuid: customer.uuid,
        campaign_id: "orders",
        metadata: %{order_id: order.id, amount: order.total}
      )
  """
  def send_from_template(template_name, recipient, variables \\ %{}, opts \\ [])
      when is_binary(template_name) do
    # Get the template from database
    case Provider.current().get_active_template_by_name(template_name) do
      nil ->
        {:error, :template_not_found}

      template ->
        # Ensure template is active
        if template.status == "active" do
          # Render template with variables in the requested locale
          locale = Keyword.get(opts, :locale, "en")
          rendered = Provider.current().render_template(template, variables, locale)

          # Build email
          email =
            new()
            |> to(recipient)
            |> from(Keyword.get(opts, :from, {get_from_name(), get_from_email()}))
            |> subject(rendered.subject)
            |> html_body(rendered.html_body)
            |> text_body(rendered.text_body)

          # Add reply-to if provided
          email =
            if reply_to = Keyword.get(opts, :reply_to) do
              reply_to(email, reply_to)
            else
              email
            end

          # Track template usage
          Provider.current().track_usage(template)

          # Extract source_module from template metadata
          source_module = Provider.current().get_source_module(template)

          # Prepare delivery options with category and source_module from template
          delivery_opts =
            opts
            |> Keyword.put(:template_name, template_name)
            |> Keyword.put(:template_uuid, template.uuid)
            |> Keyword.put_new(:campaign_id, template.category)
            |> Keyword.put(:category, template.category)
            |> Keyword.put_new(:source_module, source_module)
            |> Keyword.put(:provider, detect_provider())

          # Send email with tracking
          deliver_email(email, delivery_opts)
        else
          {:error, :template_inactive}
        end
    end
  end

  @doc """
  Delivers an email using the appropriate mailer.

  If a parent application mailer is configured, delegates to it.
  Otherwise uses the built-in PhoenixKit mailer.

  This function also integrates with the email tracking system to log
  outgoing emails when tracking is enabled.
  """
  def deliver_email(email, opts \\ []) do
    # Intercept email for tracking before sending
    tracked_email = Provider.current().intercept_before_send(email, opts)

    mailer = get_mailer()

    result =
      if mailer == __MODULE__ do
        # Use built-in mailer with runtime config for AWS
        deliver_with_runtime_config(tracked_email, mailer)
      else
        # Check if parent mailer also uses AWS SES
        app = PhoenixKit.Config.get_parent_app()
        config = Application.get_env(app, mailer, [])

        if config[:adapter] == Swoosh.Adapters.AmazonSES do
          # Parent mailer uses AWS SES, provide runtime config
          deliver_with_runtime_config(tracked_email, mailer, app)
        else
          # Non-AWS mailer, use standard delivery
          mailer.deliver(tracked_email)
        end
      end

    # Handle post-send tracking updates
    Provider.current().handle_after_send(tracked_email, result)

    result
  end

  # Deliver email with runtime configuration for AWS SES
  defp deliver_with_runtime_config(email, mailer, app \\ :phoenix_kit) do
    config =
      if app == :phoenix_kit do
        # Use PhoenixKit config for built-in mailer
        PhoenixKit.Config.get(mailer, [])
      else
        # Use parent app config for parent mailer
        PhoenixKit.Config.get_parent_app_config(mailer, [])
      end

    # If using AWS SES, override with runtime settings from DB
    runtime_config =
      if config[:adapter] == Swoosh.Adapters.AmazonSES do
        if Provider.current().aws_configured?() do
          config
          |> Keyword.put(:region, Provider.current().get_aws_region())
          |> Keyword.put(:access_key, Provider.current().get_aws_access_key())
          |> Keyword.put(:secret, Provider.current().get_aws_secret_key())
        else
          config
        end
      else
        config
      end

    # Use Swoosh.Mailer.deliver with runtime config
    Swoosh.Mailer.deliver(email, runtime_config)
  end

  @doc """
  Sends a magic link email to the user.

  Uses the 'magic_link' template from the database if available,
  falls back to hardcoded template if not found.

  ## Examples

      iex> PhoenixKit.Mailer.send_magic_link_email(user, "https://app.com/magic/token123")
      {:ok, %Swoosh.Email{}}
  """
  def send_magic_link_email(%User{} = user, magic_link_url) when is_binary(magic_link_url) do
    # Variables for template substitution
    template_variables = %{
      "user_email" => user.email,
      "magic_link_url" => magic_link_url
    }

    # Try to get template from database, fallback to text-only
    {subject, html_body, text_body, db_template} =
      case Provider.current().get_active_template_by_name("magic_link") do
        nil ->
          {
            "Your secure login link",
            nil,
            magic_link_text_body(user, magic_link_url),
            nil
          }

        template ->
          rendered = Provider.current().render_template(template, template_variables)
          {rendered.subject, rendered.html_body, rendered.text_body, template}
      end

    email =
      new()
      |> to({user.email, user.email})
      |> from({get_from_name(), get_from_email()})
      |> subject(subject)
      |> html_body(html_body)
      |> text_body(text_body)

    # Track template usage if using database template
    if db_template, do: Provider.current().track_usage(db_template)

    deliver_email(email,
      user_uuid: user.uuid,
      template_name: "magic_link",
      campaign_id: "authentication",
      category: "system",
      source_module: "users",
      provider: detect_provider()
    )
  end

  # Text version of the magic link email
  defp magic_link_text_body(_user, magic_link_url) do
    """
    Your login link: #{magic_link_url}
    This link expires in 15 minutes.
    """
  end

  # Detect current email provider from configuration
  defp detect_provider do
    mailer = get_mailer()

    if mailer == __MODULE__ do
      detect_builtin_provider()
    else
      detect_parent_app_provider(mailer)
    end
  end

  # Detect provider for built-in PhoenixKit mailer
  defp detect_builtin_provider do
    config = PhoenixKit.Config.get(PhoenixKit.Mailer, [])
    adapter = Keyword.get(config, :adapter)
    Provider.current().adapter_to_provider_name(adapter, "phoenix_kit_builtin")
  end

  # Detect provider for parent application mailer
  defp detect_parent_app_provider(mailer) when is_atom(mailer) do
    config = PhoenixKit.Config.get_parent_app_config(mailer, [])
    adapter = Keyword.get(config, :adapter)
    Provider.current().adapter_to_provider_name(adapter, "parent_app_mailer")
  end

  defp detect_parent_app_provider(_mailer), do: "unknown"

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
end
