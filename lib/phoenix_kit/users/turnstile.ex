defmodule PhoenixKit.Users.Turnstile do
  @moduledoc """
  Cloudflare Turnstile on the public forms that send mail: sign-up, the
  registration link, password reset, the magic link and the confirmation
  resend.

  Off by default. Switched on, with the site's two keys, on Settings →
  Authorization → Abuse protection. The site key is public (it goes into the
  page); the secret key is a restricted setting, encrypted at rest and never
  rendered back.

  The page shows the widget (`PhoenixKitWeb.Components.Core.TurnstileWidget`),
  which puts a one-time token into the form as `cf-turnstile-response`; the
  LiveView hands the submitted params to `PhoenixKitWeb.Users.BotCheck.run/3`,
  which calls `verify/2` BEFORE the rate limiter and before any lookup.

  ## What a failure means

    * no token, or Cloudflare says it is not valid: the request is refused;
    * Cloudflare cannot be reached, or answers with something that is not a
      verdict: the request is LET THROUGH and a warning is logged. The rate
      limits (`PhoenixKit.Users.RateLimiter`) are still in front of every one of
      these forms, so an outage at Cloudflare degrades to the protection the
      site had without Turnstile instead of closing sign-up and password reset
      for everybody;
    * Cloudflare refuses the SECRET KEY: refused, and logged as an error. The
      settings page checks the key when it is saved, so this means the key was
      rotated or revoked at Cloudflare afterwards.

  A token is good for one verification. After a submit that did not leave the
  page, the widget must be reset to mint another (`BotCheck` does).
  """

  require Logger

  alias PhoenixKit.Settings

  @verify_url "https://challenges.cloudflare.com/turnstile/v0/siteverify"
  @timeout 5_000
  # Cloudflare's documented maximum for a token.
  @max_token_length 2048

  @enabled_key "turnstile_enabled"
  @site_key "turnstile_site_key"
  @secret_key "turnstile_secret_key"

  @secret_errors ~w(invalid-input-secret missing-input-secret)

  @doc "The name of the form field the widget fills."
  @spec response_field() :: String.t()
  def response_field, do: "cf-turnstile-response"

  @doc """
  Whether the forms ask for a token: the switch is on and both keys are set.
  A switch left on with a key removed is off, never "refuse everybody".
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Settings.get_boolean_setting(@enabled_key, false) and site_key() != nil and secret() != nil
  end

  @doc "The public site key, or `nil` when none is saved."
  @spec site_key() :: String.t() | nil
  def site_key, do: present(Settings.get_setting_cached(@site_key, nil))

  @doc "The site key for a page to render the widget with, or `nil` while off."
  @spec widget_site_key() :: String.t() | nil
  def widget_site_key, do: if(enabled?(), do: site_key())

  @doc """
  What the settings page shows: the switch, the site key and WHETHER a secret
  is saved. Never the secret.
  """
  @spec config() :: %{enabled: boolean(), site_key: String.t(), secret_set?: boolean()}
  def config do
    %{
      enabled: Settings.get_boolean_setting(@enabled_key, false),
      site_key: site_key() || "",
      secret_set?: secret() != nil
    }
  end

  @doc """
  Checks the token a form submitted.

  `:ok` when Turnstile is off, when the token is good, and when Cloudflare gave
  no verdict (see the moduledoc). `{:error, :missing}` for no token,
  `{:error, :rejected}` for one Cloudflare refused.
  """
  @spec verify(term(), String.t() | nil) :: :ok | {:error, :missing | :rejected}
  def verify(token, ip_address \\ nil) do
    if enabled?(), do: do_verify(token, ip_address), else: :ok
  end

  defp do_verify(token, ip_address) do
    token = if is_binary(token), do: String.trim(token), else: ""

    cond do
      token == "" ->
        {:error, :missing}

      byte_size(token) > @max_token_length ->
        {:error, :rejected}

      true ->
        case siteverify(secret(), token, ip_address) do
          {:ok, %{"success" => true}} ->
            :ok

          {:ok, %{"error-codes" => codes}} when is_list(codes) ->
            if Enum.any?(codes, &(&1 in @secret_errors)) do
              Logger.error(
                "PhoenixKit.Turnstile: Cloudflare refused the secret key. Every protected " <>
                  "form is refusing its visitors until the key is corrected on " <>
                  "Settings -> Authorization -> Abuse protection."
              )
            end

            {:error, :rejected}

          {:ok, _body} ->
            {:error, :rejected}

          :no_verdict ->
            Logger.warning(
              "PhoenixKit.Turnstile: no verdict from Cloudflare; the request was let " <>
                "through on the rate limits alone."
            )

            :ok
        end
    end
  end

  @doc """
  Saves the switch and the keys.

  `params`: `"enabled"` (`"true"` or anything else), `"site_key"`,
  `"secret_key"` (blank keeps the saved one). `opts` are the settings history
  options (`actor_uuid:`, `source:`).

  A secret key is checked against Cloudflare before it is stored, and so is the
  saved one when the switch goes on: a wrong key would refuse every visitor of
  every protected form. Returns `{:ok, :saved}`, or `{:ok, :unverified}` when
  Cloudflare could not be asked, or

    * `{:error, :site_key_required}` / `{:error, :secret_key_required}` -
      switching on without one;
    * `{:error, :invalid_secret}` - Cloudflare does not know the secret key.

  The caller authorizes (`settings.security`).
  """
  @spec save_config(map(), keyword()) ::
          {:ok, :saved | :unverified}
          | {:error, :site_key_required | :secret_key_required | :invalid_secret | term()}
  def save_config(params, opts \\ []) when is_map(params) do
    enabled? = params["enabled"] == "true"
    site_key = present(params["site_key"])
    new_secret = present(params["secret_key"])
    secret = new_secret || secret()

    cond do
      enabled? and site_key == nil ->
        {:error, :site_key_required}

      enabled? and secret == nil ->
        {:error, :secret_key_required}

      true ->
        # Only a key about to be relied on, or about to be stored, is probed.
        probe = if secret && (enabled? or new_secret), do: check_secret(secret), else: :ok

        with probe when probe in [:ok, :unknown] <- probe,
             {:ok, _} <- Settings.update_setting(@site_key, site_key || "", opts),
             {:ok, _} <- store_secret(new_secret, opts),
             {:ok, _} <- Settings.update_boolean_setting(@enabled_key, enabled?, opts) do
          {:ok, if(probe == :ok, do: :saved, else: :unverified)}
        end
    end
  end

  defp store_secret(nil, _opts), do: {:ok, :unchanged}
  defp store_secret(secret, opts), do: Settings.update_setting(@secret_key, secret, opts)

  @doc """
  Asks Cloudflare whether it knows `secret`, with a token that cannot be valid:
  a known secret is answered `invalid-input-response`, an unknown one
  `invalid-input-secret`. `:unknown` when there was no answer to read.
  """
  @spec check_secret(String.t()) :: :ok | :unknown | {:error, :invalid_secret}
  def check_secret(secret) when is_binary(secret) do
    case siteverify(secret, "phoenix-kit-key-check", nil) do
      {:ok, %{"error-codes" => codes}} when is_list(codes) ->
        if Enum.any?(codes, &(&1 in @secret_errors)), do: {:error, :invalid_secret}, else: :ok

      # Cloudflare's always-pass test keys accept any token.
      {:ok, %{"success" => true}} ->
        :ok

      _ ->
        :unknown
    end
  end

  # `{:ok, body}` for a verdict (a JSON object from a 200), `:no_verdict` for
  # everything else. Nothing of the request or the answer is logged: the secret
  # and the token are both in the request.
  defp siteverify(secret, token, ip_address) do
    form =
      [secret: secret, response: token] ++
        if(is_binary(ip_address) and ip_address not in ["", "unknown"],
          do: [remoteip: ip_address],
          else: []
        )

    options =
      [form: form, receive_timeout: @timeout, connect_options: [timeout: @timeout], retry: false] ++
        req_options()

    case Req.post(@verify_url, options) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      _ -> :no_verdict
    end
  rescue
    _ -> :no_verdict
  catch
    :exit, _ -> :no_verdict
  end

  # Tests route the call through `Req.Test`
  # (`config :phoenix_kit, :turnstile_req_options, plug: ...`). Unset in production.
  defp req_options do
    :phoenix_kit |> Application.get_env(:turnstile_req_options, []) |> Keyword.take([:plug])
  end

  defp secret, do: present(Settings.get_setting_cached(@secret_key, nil))

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil
end
