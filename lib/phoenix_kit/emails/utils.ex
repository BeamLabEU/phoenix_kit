defmodule PhoenixKit.Emails.Utils do
  @moduledoc """
  Utility functions for email handling in PhoenixKit.

  This module contains helper functions for email provider detection,
  configuration analysis, and other email-related utilities.
  """

  alias PhoenixKit.Config

  @doc """
  Converts Swoosh adapter module to provider name.

  Maps common Swoosh mailer adapters to standardized provider names
  used throughout PhoenixKit's email tracking system.

  ## Parameters

  - `adapter` - The Swoosh adapter module (e.g., Swoosh.Adapters.AmazonSES)
  - `default_name` - Default provider name to return if adapter is unknown

  ## Examples

      iex> PhoenixKit.Emails.Utils.adapter_to_provider_name(Swoosh.Adapters.AmazonSES, "unknown")
      "aws_ses"

      iex> PhoenixKit.Emails.Utils.adapter_to_provider_name(Swoosh.Adapters.SMTP, "unknown")
      "smtp"

      iex> PhoenixKit.Emails.Utils.adapter_to_provider_name(Some.Custom.Adapter, "custom")
      "custom"
  """
  @spec adapter_to_provider_name(module() | nil, String.t()) :: String.t()
  def adapter_to_provider_name(adapter, default_name \\ "unknown") do
    case adapter do
      Swoosh.Adapters.AmazonSES -> "aws_ses"
      Swoosh.Adapters.SMTP -> "smtp"
      Swoosh.Adapters.Sendgrid -> "sendgrid"
      Swoosh.Adapters.Mailgun -> "mailgun"
      Swoosh.Adapters.Local -> "local"
      _ -> default_name
    end
  end

  @doc """
  Detects email provider from application configuration.

  Analyzes the configured mailer adapter to determine which email
  provider is being used (AWS SES, SMTP, SendGrid, etc.).

  ## Examples

      iex> PhoenixKit.Emails.Utils.detect_provider_from_config()
      "aws_ses"

      iex> PhoenixKit.Emails.Utils.detect_provider_from_config()
      "smtp"
  """
  @spec detect_provider_from_config() :: String.t()
  def detect_provider_from_config do
    case PhoenixKit.Config.get(:mailer) do
      {:ok, mailer} when not is_nil(mailer) ->
        # Try to determine provider from mailer configuration
        config = Config.get(mailer, [])
        adapter = Keyword.get(config, :adapter)
        adapter_to_provider_name(adapter, "unknown")

      _ ->
        "unknown"
    end
  end
end
