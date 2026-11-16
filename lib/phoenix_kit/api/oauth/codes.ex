defmodule PhoenixKit.API.OAuth.Codes do
  @moduledoc """
  Authorization codes (`PhoenixKit.API.OAuth.Code`): made when a person allows a request,
  exchanged once at the token endpoint.

  A code is 32 random bytes (base64url), good for 60 seconds, stored as its SHA-256, bound to
  the grant, the `redirect_uri` and the PKCE challenge of the request it came from.

  `redeem/1` is the single atomic step the token endpoint starts from:

      UPDATE codes SET used_at = now WHERE code_hash = $1 AND used_at IS NULL AND expires_at > now RETURNING ...

  Exactly one of any number of simultaneous exchanges wins it. A code presented after it was
  used is `:reused` (RFC 6749 section 4.1.2: the caller then revokes the grant and the tokens
  issued from it); one that ran out unused, or that never existed, is `:invalid`.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.API.OAuth.Code
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.RepoHelper

  @ttl_seconds 60
  @secret_bytes 32
  @pattern ~r/\A[A-Za-z0-9_-]{43}\z/

  @doc "Seconds a code lives."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc """
  Makes a code for `grant`: `{:ok, code, row}`. `attrs` takes `redirect_uri` and
  `code_challenge`. The code is shown once and not stored.
  """
  @spec issue(Grant.t(), map()) :: {:ok, String.t(), Code.t()} | {:error, Ecto.Changeset.t()}
  def issue(%Grant{uuid: grant_uuid}, attrs) when is_map(attrs) do
    secret = :crypto.strong_rand_bytes(@secret_bytes)

    row = %Code{
      code_hash: hash(secret),
      grant_uuid: grant_uuid,
      redirect_uri: Map.fetch!(attrs, :redirect_uri),
      code_challenge: Map.fetch!(attrs, :code_challenge),
      expires_at: DateTime.add(now(), @ttl_seconds, :second)
    }

    with {:ok, row} <- repo().insert(row),
         do: {:ok, Base.url_encode64(secret, padding: false), row}
  end

  @doc """
  Takes the code `presented` off the table, once. `{:ok, row}` for the winner;
  `{:error, :reused, row}` for a code that was already used; `{:error, :invalid}` for a code that
  is unknown, malformed or ran out unused.
  """
  @spec redeem(term()) :: {:ok, Code.t()} | {:error, :reused, Code.t()} | {:error, :invalid}
  def redeem(presented) do
    case parse(presented) do
      {:ok, hash} -> redeem_hash(hash)
      :error -> {:error, :invalid}
    end
  end

  defp redeem_hash(hash) do
    now = now()

    {count, rows} =
      repo().update_all(
        from(c in Code,
          where: c.code_hash == ^hash and is_nil(c.used_at) and c.expires_at > ^now,
          select: c
        ),
        set: [used_at: now]
      )

    case {count, rows} do
      {1, [row]} -> {:ok, row}
      {0, _} -> classify(hash)
    end
  end

  # Nothing was redeemed: a code used before is a replay, anything else is just invalid.
  defp classify(hash) do
    case repo().one(from(c in Code, where: c.code_hash == ^hash)) do
      %Code{used_at: %DateTime{}} = row -> {:error, :reused, row}
      _ -> {:error, :invalid}
    end
  end

  defp parse(presented) when is_binary(presented) do
    with true <- Regex.match?(@pattern, presented),
         {:ok, secret} <- Base.url_decode64(presented, padding: false),
         @secret_bytes <- byte_size(secret),
         true <- Base.url_encode64(secret, padding: false) == presented do
      {:ok, hash(secret)}
    else
      _ -> :error
    end
  end

  defp parse(_presented), do: :error

  defp hash(secret), do: :crypto.hash(:sha256, secret)

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp repo, do: RepoHelper.repo()
end
