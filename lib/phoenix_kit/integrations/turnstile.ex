defmodule PhoenixKit.Integrations.Turnstile do
  @moduledoc """
  Cloudflare Turnstile for site forms. Store the chosen website connection UUID
  with the consuming feature. Render its public site key and verify the submitted
  token on the server. Each consumer decides how to handle a service outage.
  """
  @behaviour PhoenixKit.Integrations.Validator
  use Gettext, backend: PhoenixKitWeb.Gettext
  require Logger
  alias PhoenixKit.Integrations

  @verify_url "https://challenges.cloudflare.com/turnstile/v0/siteverify"
  @timeout 5_000
  # Cloudflare's documented maximum for a token.
  @max_token_length 2048

  @secret_errors ~w(invalid-input-secret missing-input-secret)

  @doc "The public widget key of a verified website connection."
  @spec site_key(String.t()) :: String.t() | nil
  def site_key(uuid) do
    case connection(uuid) do
      {:ok, data} -> data["site_key"]
      _ -> nil
    end
  end

  @doc "Verifies a form token using the website connection selected by the consumer."
  @spec verify(String.t(), term(), String.t() | nil) ::
          :ok | {:error, :missing | :rejected | :unavailable | :not_configured}
  def verify(uuid, token, ip_address \\ nil) do
    with {:ok, data} <- connection(uuid),
         do: verify_with_secret(data["secret_key"], token, ip_address)
  end

  defp connection(uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         {:ok, %{provider: provider, data: data}} <-
           Integrations.get_integration_by_uuid(uuid, :system),
         %{capabilities: capabilities} <- Integrations.Providers.get(provider),
         true <- :turnstile in capabilities,
         %{"status" => "connected", "secret_key" => secret, "site_key" => site} <- data,
         true <- is_binary(secret) and secret != "" and is_binary(site) and site != "" do
      {:ok, data}
    else
      _ -> {:error, :not_configured}
    end
  end

  @impl true
  def validate_connection(%{"secret_key" => secret}) do
    case check_secret(secret) do
      :ok -> :ok
      :unknown -> {:inconclusive, gettext("Cloudflare could not verify the secret key.")}
      {:error, :invalid_secret} -> {:error, gettext("Cloudflare rejected the secret key.")}
    end
  end

  @doc "The name of the form field the widget fills."
  @spec response_field() :: String.t()
  def response_field, do: "cf-turnstile-response"

  @doc false
  def verify_with_secret(secret, token, ip_address) do
    token = if is_binary(token), do: String.trim(token), else: ""

    cond do
      token == "" ->
        {:error, :missing}

      byte_size(token) > @max_token_length ->
        {:error, :rejected}

      true ->
        case siteverify(secret, token, ip_address) do
          {:ok, %{"success" => true}} ->
            :ok

          {:ok, %{"error-codes" => codes}} when is_list(codes) ->
            if Enum.any?(codes, &(&1 in @secret_errors)) do
              Logger.error(
                "PhoenixKit.Turnstile: Cloudflare refused the widget secret. " <>
                  "Check the credentials for the affected widget."
              )
            end

            {:error, :rejected}

          {:ok, _body} ->
            {:error, :rejected}

          :no_verdict ->
            {:error, :unavailable}
        end
    end
  end

  @doc """
  Asks Cloudflare whether it knows `secret`, with a token that cannot be valid:
  a known secret is answered `invalid-input-response`, an unknown one
  `invalid-input-secret`. `:unknown` when there was no answer to read.
  """
  @spec check_secret(String.t()) :: :ok | :unknown | {:error, :invalid_secret}
  def check_secret(secret) when is_binary(secret) do
    case siteverify(secret, "phoenix-kit-key-check", nil) do
      {:ok, %{"error-codes" => codes}} when is_list(codes) ->
        cond do
          Enum.any?(codes, &(&1 in @secret_errors)) -> {:error, :invalid_secret}
          "invalid-input-response" in codes -> :ok
          true -> :unknown
        end

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
end
