defmodule PhoenixKit.Users.Turnstile do
  @moduledoc """
  Selects Turnstile protection for public auth forms. The Authorization page
  chooses a website integration. Installations with saved standalone keys keep
  using them until a connection is selected.
  """
  require Logger
  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Turnstile, as: Adapter
  alias PhoenixKit.Settings

  @auth_key "turnstile_auth"
  @enabled_key "turnstile_enabled"
  @site_key "turnstile_site_key"
  @secret_key "turnstile_secret_key"

  @default_forms ~w(registration registration_link password_reset magic_link confirmation_resend)

  @forms ["password_login" | @default_forms]

  def forms, do: @forms

  defdelegate response_field(), to: Adapter
  defdelegate check_secret(secret), to: Adapter

  def selection do
    saved =
      Settings.get_json_setting_cached(@auth_key) ||
        %{"enabled" => Settings.get_boolean_setting(@enabled_key, false), "connection" => ""}

    Map.put_new(saved, "forms", @default_forms)
  end

  @doc "Verified website connections available to protect the auth forms."
  def choices, do: Integrations.connected_choices(:turnstile, :system)

  @doc "Saves the auth switch and chosen connection together. The caller authorizes settings.security."
  def save_selection(params, opts) do
    enabled = params["enabled"] == "true"
    uuid = params["connection"] || ""

    valid? =
      cond do
        uuid == "" -> not enabled or legacy_configured?()
        not enabled and uuid == selection()["connection"] -> true
        true -> Enum.any?(choices(), fn {id, _} -> id == uuid end)
      end

    with true <- valid? || {:error, :invalid_connection},
         {:ok, forms} <- selected_forms(params) do
      Settings.update_json_setting(
        @auth_key,
        %{"enabled" => enabled, "connection" => uuid, "forms" => forms},
        opts
      )
    end
  end

  defp selected_forms(%{"forms" => forms}) when is_list(forms) do
    if Enum.all?(forms, &(&1 in ["" | @forms])),
      do: {:ok, Enum.filter(@forms, &(&1 in forms))},
      else: {:error, :invalid_forms}
  end

  defp selected_forms(%{"forms" => _}), do: {:error, :invalid_forms}
  defp selected_forms(_params), do: {:ok, selection()["forms"]}

  def legacy_configured?, do: legacy_site_key() != nil and secret() != nil

  def enabled?(form \\ nil), do: protecting?(selection(), form) != nil

  # The public key of a form that is actually checking tokens, or nil. A switch
  # left on with nothing to check with (no legacy keys, or a connection that was
  # removed or no longer verifies) is off: the widget would be hidden and a
  # refusal would lock every protected door, including password sign-in.
  defp protecting?(selection, form) do
    key = site_key(selection)

    if (is_nil(form) or form_selected?(selection, form)) and enabled_selection?(selection) and
         present_key?(key),
       do: key
  end

  defp form_selected?(%{"forms" => forms}, form) when is_list(forms), do: form in forms
  defp form_selected?(_, _), do: false

  defp present_key?(key) when is_binary(key) and key != "", do: true
  defp present_key?(_), do: false

  defp enabled_selection?(selection) do
    case selection do
      %{"enabled" => true, "connection" => ""} -> legacy_configured?()
      %{"enabled" => enabled} -> enabled
    end
  end

  def site_key, do: site_key(selection())

  defp site_key(%{"connection" => ""}), do: legacy_site_key()
  defp site_key(%{"connection" => uuid}) when is_binary(uuid), do: Adapter.site_key(uuid)
  defp site_key(_), do: nil

  defp legacy_site_key, do: present(Settings.get_setting_cached(@site_key, nil))

  @doc "The site key for a page to render the widget with, or `nil` while off."
  def widget_site_key(form \\ nil), do: protecting?(selection(), form)

  @doc """
  What the settings page shows: the switch, the site key and WHETHER a secret
  is saved. Never the secret.
  """
  @spec config() :: %{enabled: boolean(), site_key: String.t(), secret_set?: boolean()}
  def config do
    selection = selection()
    site = site_key()

    %{
      enabled: selection["enabled"],
      site_key: site || "",
      secret_set?: if(selection["connection"] == "", do: secret() != nil, else: site != nil)
    }
  end

  @doc """
  Checks the token a form submitted.

  `:ok` when Turnstile is off, when the token is good, when Cloudflare gave
  no verdict, and when the selected connection can no longer verify (the same
  as a switch left on without keys — refusing here would lock the doors with
  no widget on the page). `{:error, :missing}` for no token,
  `{:error, :rejected}` for one Cloudflare refused.
  """
  @spec verify(term(), String.t() | nil) :: :ok | {:error, :missing | :rejected}
  def verify(token, ip_address \\ nil) do
    result =
      case selection() do
        %{"enabled" => false} ->
          :ok

        %{"connection" => ""} ->
          if legacy_configured?(),
            do: Adapter.verify_with_secret(secret(), token, ip_address),
            else: :ok

        %{"connection" => uuid} when is_binary(uuid) ->
          Adapter.verify(uuid, token, ip_address)

        _ ->
          :ok
      end

    case result do
      {:error, :unavailable} ->
        Logger.warning("PhoenixKit.Turnstile: Cloudflare unavailable, using auth rate limits")
        :ok

      {:error, :not_configured} ->
        Logger.error(
          "PhoenixKit.Turnstile: protection is switched on but the connection cannot verify tokens, so this request was not checked"
        )

        :ok

      verdict ->
        verdict
    end
  end

  @doc """
  Saves the standalone settings for installations using the legacy auth configuration.
  Once a connection is selected, auth uses `save_selection/2` instead.

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

  defp secret, do: present(Settings.get_setting_cached(@secret_key, nil))

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil
end
