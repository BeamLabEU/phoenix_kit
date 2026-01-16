defmodule Mix.Tasks.PhoenixKit.SeedTemplates do
  @moduledoc """
  Seeds the database with system email templates.

  This task creates the default system templates for authentication and core functionality.
  It's safe to run multiple times as it will not create duplicate templates.

  ## Usage

      mix phoenix_kit.seed_templates

  ## Options

      --force    Force recreation of existing templates (will update content)
      --quiet    Run without output

  ## Examples

      # Seed templates normally
      mix phoenix_kit.seed_templates

      # Force update existing templates
      mix phoenix_kit.seed_templates --force

      # Run quietly without output
      mix phoenix_kit.seed_templates --quiet

  ## System Templates

  This task will create the following system templates:

  - **magic_link** - Magic link authentication email
  - **register** - User registration confirmation email
  - **reset_password** - Password reset email
  - **test_email** - Test email for tracking verification
  - **update_email** - Email change confirmation

  All templates are marked as system templates and cannot be deleted through the UI.
  """

  use Mix.Task

  alias PhoenixKit.Modules.Emails.Templates

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _args, _invalid} =
      OptionParser.parse(args, switches: [force: :boolean, quiet: :boolean])

    force = Keyword.get(opts, :force, false)
    quiet = Keyword.get(opts, :quiet, false)

    unless quiet do
      IO.puts("Seeding system email templates...")
    end

    # Ensure the repo is available and started
    case PhoenixKit.Config.get(:repo) do
      {:ok, repo_module} ->
        try do
          _ = repo_module.start_link()
        rescue
          # Repo might already be started
          _ -> :ok
        end

      :not_found ->
        unless quiet do
          IO.puts("❌ PhoenixKit repository not configured.")
          IO.puts("Please configure PhoenixKit in your application:")
          IO.puts("")
          IO.puts("    config :phoenix_kit,")
          IO.puts("      repo: YourApp.Repo")
          IO.puts("")
          IO.puts("Then run this command from your application directory.")
        end

        System.halt(1)
    end

    case seed_templates(force, quiet) do
      {:ok, templates} ->
        unless quiet do
          IO.puts("✅ Successfully seeded #{length(templates)} system email templates:")

          for template <- templates do
            status_icon = if template.status == "active", do: "🟢", else: "🟡"
            IO.puts("   #{status_icon} #{template.name} (#{template.display_name})")
          end

          IO.puts("")
          IO.puts("Templates are now available in the admin panel at:")
          IO.puts("  {your_app_url}/phoenix_kit/admin/emails/templates")
        end

        :ok

      {:error, :seed_failed} ->
        IO.puts("❌ Failed to seed some system templates. Check the logs for details.")
        System.halt(1)
    end
  end

  defp seed_templates(force, quiet) do
    if force do
      # Force mode: update existing templates
      seed_with_force(quiet)
    else
      # Normal mode: only create missing templates
      Templates.seed_system_templates()
    end
  end

  defp seed_with_force(quiet) do
    unless quiet do
      IO.puts("🔄 Force mode: Updating existing system templates...")
    end

    system_templates = [
      %{
        name: "magic_link",
        slug: "magic-link",
        display_name: "Magic Link Authentication",
        description: "Secure login link email for passwordless authentication",
        subject: "Your secure login link",
        html_body: Templates.magic_link_html_template(),
        text_body: Templates.magic_link_text_template(),
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
        html_body: Templates.register_html_template(),
        text_body: Templates.register_text_template(),
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
        html_body: Templates.reset_password_html_template(),
        text_body: Templates.reset_password_text_template(),
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
        html_body: Templates.test_email_html_template(),
        text_body: Templates.test_email_text_template(),
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
        html_body: Templates.update_email_html_template(),
        text_body: Templates.update_email_text_template(),
        category: "system",
        status: "active",
        is_system: true,
        variables: %{
          "user_email" => "User's email address",
          "update_url" => "URL for email update confirmation"
        },
        metadata: %{"source_module" => "users"}
      }
    ]

    results =
      Enum.map(system_templates, fn template_attrs ->
        case Templates.get_template_by_name(template_attrs.name) do
          nil ->
            # Template doesn't exist, create it
            Templates.create_template(template_attrs)

          existing_template ->
            # Template exists, update it
            Templates.update_template(existing_template, template_attrs)
        end
      end)

    if Enum.all?(results, fn {status, _} -> status == :ok end) do
      templates = Enum.map(results, fn {:ok, template} -> template end)
      {:ok, templates}
    else
      errors = Enum.filter(results, fn {status, _} -> status == :error end)

      unless quiet do
        Mix.shell().error("Errors occurred during seeding: #{inspect(errors)}")
      end

      {:error, :seed_failed}
    end
  end
end
