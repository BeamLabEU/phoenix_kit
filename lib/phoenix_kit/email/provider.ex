defmodule PhoenixKit.Email.Provider do
  @moduledoc """
  Unified email provider behaviour.

  Covers interception (pre/post send hooks), DB templates, AWS config,
  and provider detection. The emails package implements this fully.
  The DefaultProvider is a no-op that passes emails through unchanged.
  """

  # Interception
  @callback intercept_before_send(Swoosh.Email.t(), keyword()) :: Swoosh.Email.t()
  @callback handle_after_send(Swoosh.Email.t(), {:ok, any()} | {:error, any()}) :: :ok

  # Templates
  @callback get_active_template_by_name(String.t()) :: map() | nil
  @callback render_template(map(), map()) :: map()
  @callback render_template(map(), map(), String.t()) :: map()
  @callback track_usage(map()) :: :ok
  @callback get_source_module(map()) :: String.t() | nil

  # AWS config
  @callback get_aws_region() :: String.t()
  @callback get_aws_access_key() :: String.t()
  @callback get_aws_secret_key() :: String.t()
  @callback aws_configured?() :: boolean()

  # Provider detection
  @callback adapter_to_provider_name(atom(), String.t()) :: String.t()

  # Test email (only supported by emails package)
  @callback send_test_tracking_email(String.t(), String.t() | nil) ::
              {:ok, Swoosh.Email.t()} | {:error, any()}
end
