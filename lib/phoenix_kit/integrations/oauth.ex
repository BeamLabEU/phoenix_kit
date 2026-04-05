defmodule PhoenixKit.Integrations.OAuth do
  @moduledoc """
  Generic OAuth 2.0 flow for service integrations.

  Handles authorization URL generation, code-to-token exchange,
  token refresh, and userinfo fetching. Provider-specific details
  (URLs, scopes, extra params) come from the provider definition
  in `PhoenixKit.Integrations.Providers`.
  """

  require Logger

  @doc """
  Build the OAuth authorization URL for a provider.

  Requires `client_id` to be present in the integration data and
  the provider to have `oauth_config` with an `auth_url`.
  """
  @spec authorization_url(map(), map(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, atom()}
  def authorization_url(oauth_config, integration_data, redirect_uri, extra_scopes \\ nil) do
    client_id = integration_data["client_id"]

    if is_binary(client_id) and client_id != "" do
      scopes =
        extra_scopes || oauth_config[:default_scopes] || oauth_config["default_scopes"] || ""

      params =
        %{
          "client_id" => client_id,
          "redirect_uri" => redirect_uri,
          "response_type" => "code",
          "scope" => scopes
        }
        |> Map.merge(oauth_config[:auth_params] || oauth_config["auth_params"] || %{})

      url = "#{oauth_config[:auth_url] || oauth_config["auth_url"]}?#{URI.encode_query(params)}"
      {:ok, url}
    else
      {:error, :client_id_not_configured}
    end
  end

  @doc """
  Exchange an authorization code for access and refresh tokens.
  """
  @spec exchange_code(map(), map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def exchange_code(oauth_config, integration_data, code, redirect_uri) do
    with {:ok, client_id, client_secret} <- validate_client_credentials(integration_data) do
      token_url = oauth_config[:token_url] || oauth_config["token_url"]

      token_url
      |> post_token_request(
        code: code,
        client_id: client_id,
        client_secret: client_secret,
        redirect_uri: redirect_uri,
        grant_type: "authorization_code"
      )
      |> handle_token_response(integration_data)
    end
  end

  @doc """
  Refresh an expired access token using the refresh token.
  """
  @spec refresh_access_token(map(), map()) :: {:ok, String.t(), map()} | {:error, term()}
  def refresh_access_token(oauth_config, integration_data) do
    refresh_token = integration_data["refresh_token"]

    if is_binary(refresh_token) and refresh_token != "" do
      with {:ok, client_id, client_secret} <- validate_client_credentials(integration_data) do
        token_url = oauth_config[:token_url] || oauth_config["token_url"]

        case post_token_request(token_url,
               refresh_token: refresh_token,
               client_id: client_id,
               client_secret: client_secret,
               grant_type: "refresh_token"
             ) do
          {:ok, %{status: 200, body: %{"access_token" => new_token} = body}} ->
            updated_fields = %{
              "access_token" => new_token,
              "expires_at" => compute_expires_at(body["expires_in"]),
              "token_obtained_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }

            {:ok, new_token, updated_fields}

          {:ok, %{status: status}} ->
            log_token_error("Token refresh failed", status)
            {:error, {:refresh_failed, status}}

          {:error, reason} ->
            Logger.warning("[Integrations.OAuth] Token refresh error: #{inspect(reason)}")
            {:error, reason}
        end
      end
    else
      {:error, :no_refresh_token}
    end
  end

  @doc """
  Fetch user info from the provider's userinfo endpoint.

  Returns a map with at least `"email"` if available.
  """
  @spec fetch_userinfo(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_userinfo(oauth_config, access_token) do
    userinfo_url = oauth_config[:userinfo_url] || oauth_config["userinfo_url"]

    if is_binary(userinfo_url) and userinfo_url != "" do
      case Req.get(userinfo_url, headers: [{"authorization", "Bearer #{access_token}"}]) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          {:ok, body}

        {:ok, %{status: status}} ->
          Logger.warning("[Integrations.OAuth] Userinfo request returned status #{status}")
          {:error, {:userinfo_failed, status}}

        {:error, reason} ->
          Logger.warning("[Integrations.OAuth] Userinfo request failed: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:ok, %{}}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp compute_expires_at(nil), do: nil

  defp compute_expires_at(expires_in) when is_integer(expires_in) do
    DateTime.utc_now()
    |> DateTime.add(expires_in, :second)
    |> DateTime.to_iso8601()
  end

  defp compute_expires_at(_), do: nil

  defp validate_client_credentials(data) do
    client_id = data["client_id"]
    client_secret = data["client_secret"]

    if is_binary(client_id) and client_id != "" and
         is_binary(client_secret) and client_secret != "" do
      {:ok, client_id, client_secret}
    else
      {:error, :client_credentials_not_configured}
    end
  end

  defp post_token_request(url, form_params) do
    Req.post(url, form: form_params)
  end

  defp handle_token_response(
         {:ok, %{status: 200, body: %{"access_token" => _} = body}},
         integration_data
       ) do
    token_data = %{
      "access_token" => body["access_token"],
      "refresh_token" => body["refresh_token"] || integration_data["refresh_token"],
      "token_type" => body["token_type"] || "Bearer",
      "expires_at" => compute_expires_at(body["expires_in"]),
      "token_obtained_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:ok, token_data}
  end

  defp handle_token_response({:ok, %{status: status}}, _integration_data) do
    log_token_error("Token exchange failed", status)
    {:error, {:token_exchange_failed, status}}
  end

  defp handle_token_response({:error, reason}, _integration_data) do
    Logger.warning("[Integrations.OAuth] Token exchange error: #{inspect(reason)}")
    {:error, reason}
  end

  defp log_token_error(message, status) do
    Logger.warning("[Integrations.OAuth] #{message}: status=#{status}")
  end
end
