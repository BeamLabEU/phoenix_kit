defmodule PhoenixKit.API.OAuth.Clients do
  @moduledoc """
  The applications that may ask for access (`PhoenixKit.API.OAuth.Client`).

  A client enters the table in one of three ways: an administrator names it
  (`register_preregistered/1`), it registers itself (`PhoenixKit.API.OAuth.Registration`,
  Dynamic Client Registration), or it names itself by the URL of a metadata document
  (`PhoenixKit.API.OAuth.Cimd`) that `resolve/2` fetches the first time the URL is presented.
  Looking one up is by its row (`get/1`) or by the `client_id` it presents (`get_by_client_id/1`);
  an authorization request goes through `resolve/2`.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.API.OAuth.Cimd
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.ClientPolicy
  alias PhoenixKit.API.OAuth.Input
  alias PhoenixKit.API.OAuth.Limits
  alias PhoenixKit.API.OAuth.RedirectUri
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  @max_name_length 160

  @doc """
  Registers a client an administrator named: `attrs` takes `client_id` (required, unique, at most
  2048 characters), `client_name` (cut to 160 characters), `client_uri` and `redirect_uris`.

  Every redirect URI must be one a client may register (`PhoenixKit.API.OAuth.RedirectUri`:
  `https`, or `http` to the loopback; no fragment, no wildcard, no custom scheme), and the text
  fields must be storable (`PhoenixKit.API.OAuth.Input`: no NUL byte, valid UTF-8).

  Returns the row, or a changeset error (a taken `client_id` is `{"has already been taken", ...}`
  on `:client_id`).
  """
  @spec register_preregistered(map()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def register_preregistered(attrs) when is_map(attrs) do
    %Client{kind: "preregistered"}
    |> Ecto.Changeset.cast(attrs, [:client_id, :client_name, :client_uri, :redirect_uris])
    |> Ecto.Changeset.validate_required([:client_id])
    |> Ecto.Changeset.update_change(:client_name, &String.slice(&1, 0, @max_name_length))
    |> Ecto.Changeset.validate_length(:client_id, max: 2048)
    |> validate_storable([:client_id, :client_name, :client_uri])
    |> Ecto.Changeset.validate_change(:redirect_uris, fn :redirect_uris, uris ->
      if Enum.all?(uris, &RedirectUri.valid?/1),
        do: [],
        else: [redirect_uris: "must be https or loopback http URIs without fragment or wildcard"]
    end)
    |> Ecto.Changeset.unique_constraint(:client_id)
    |> repo().insert()
  end

  # A NUL byte or bytes that are not UTF-8 cannot be stored: a changeset error, not a raised
  # database error.
  defp validate_storable(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      Ecto.Changeset.validate_change(acc, field, fn _field, value ->
        if Input.valid?(value), do: [], else: [{field, "must be valid text"}]
      end)
    end)
  end

  @doc """
  A client's own name made safe to store and show: control, format and line-separator characters
  removed, trimmed, cut to 160 characters. `nil` when what is left is empty or `name` is not text.
  """
  @spec clean_name(term()) :: String.t() | nil
  def clean_name(name) when is_binary(name) do
    cleaned =
      name
      |> String.replace(~r/[\p{C}\p{Zl}\p{Zp}]/u, "")
      |> String.trim()
      |> String.slice(0, @max_name_length)
      |> String.trim()

    if cleaned == "", do: nil, else: cleaned
  end

  def clean_name(_name), do: nil

  @doc """
  A client's home page URL if it is one an `https` link can be made of (a host, no userinfo, no
  fragment, no whitespace or control character, 2048 bytes at most), else `nil`.
  """
  @spec clean_uri(term()) :: String.t() | nil
  def clean_uri(uri) when is_binary(uri) and byte_size(uri) in 1..2048 do
    with false <- Regex.match?(~r/[\x00-\x20\x7F\\]/, uri),
         {:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}} <- URI.new(uri),
         true <- is_binary(host) and host != "" do
      uri
    else
      _ -> nil
    end
  end

  def clean_uri(_uri), do: nil

  @doc """
  The client an authorization request names by `client_id`, or why there is none.

    * a stored client that is not a metadata document client (pre-registered, registered) is
      returned as it is;
    * a `client_id` that is the URL of a metadata document is served from the table while what was
      fetched is fresh (`metadata_expires_at`), and otherwise fetched again: the form of the URL is
      judged first, then the host policy, then the fetch limits (per network and per client), then
      the document is fetched (`PhoenixKit.API.OAuth.Cimd`), judged by the policy again with the
      redirect hosts it names, and stored. A document that cannot be had is refused, never
      remembered, and a stale row is not used in its place;
    * anything else is unknown.

  The policy (`PhoenixKit.API.OAuth.ClientPolicy`) also judges a client that is already stored,
  every time. `opts`: `:ip`, the address the request came from, for the fetch limit.

  Errors: `:unknown_client`, `:not_allowed`, `:rate_limited`, `:busy` (too many fetches run
  already), `:fetch_failed`.
  """
  @spec resolve(term(), keyword()) ::
          {:ok, Client.t()}
          | {:error, :unknown_client | :not_allowed | :rate_limited | :busy | :fetch_failed}
  def resolve(client_id, opts \\ [])

  def resolve(client_id, opts) when is_binary(client_id) and byte_size(client_id) in 1..2048 do
    case get_by_client_id(client_id) do
      %Client{kind: "cimd"} = row -> cached_or_fetch(row, opts)
      %Client{} = client -> allowed(client)
      nil -> fetch_new(client_id, opts)
    end
  end

  def resolve(_client_id, _opts), do: {:error, :unknown_client}

  defp cached_or_fetch(%Client{} = row, opts) do
    if fresh?(row), do: allowed(row), else: fetch(row.client_id, opts)
  end

  defp fetch_new(client_id, opts) do
    case Cimd.validate_client_id(client_id) do
      :ok -> fetch(client_id, opts)
      {:error, :invalid_client_id} -> {:error, :unknown_client}
    end
  end

  defp fresh?(%Client{metadata_expires_at: %DateTime{} = expires}),
    do: DateTime.compare(expires, DateTime.utc_now()) == :gt

  defp fresh?(_client), do: false

  defp allowed(%Client{} = client) do
    if ClientPolicy.allowed?(client.kind, client.client_id, client.redirect_uris),
      do: {:ok, client},
      else: {:error, :not_allowed}
  end

  defp fetch(client_id, opts) do
    with :ok <- host_allowed(client_id, []),
         :ok <- within_limits(client_id, opts[:ip]),
         {:ok, document} <- fetch_document(client_id),
         :ok <- host_allowed(client_id, document.redirect_uris) do
      store(client_id, document)
    end
  end

  defp host_allowed(client_id, redirect_uris) do
    if ClientPolicy.allowed?("cimd", client_id, redirect_uris),
      do: :ok,
      else: {:error, :not_allowed}
  end

  defp within_limits(client_id, ip) do
    with :ok <- Limits.hit(:cimd_ip, ip),
         :ok <- Limits.hit(:cimd_client, client_id) do
      :ok
    else
      {:error, _retry_after} -> {:error, :rate_limited}
    end
  end

  defp fetch_document(client_id) do
    case Cimd.fetch(client_id) do
      {:ok, document} -> {:ok, document}
      {:error, :busy} -> {:error, :busy}
      {:error, _reason} -> {:error, :fetch_failed}
    end
  end

  # One row per document URL, whoever asks first: the insert races are settled by the unique
  # `client_id` (the update applies to a metadata document row only), and the row is read back.
  defp store(client_id, document) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    expires = DateTime.add(now, document.ttl, :second)

    fields = [
      client_name: document.client_name,
      client_uri: document.client_uri,
      redirect_uris: document.redirect_uris,
      metadata_fetched_at: now,
      metadata_expires_at: expires
    ]

    update =
      from(c in Client,
        where: c.kind == "cimd",
        update: [set: ^Keyword.put(fields, :updated_at, now)]
      )

    {:ok, _row} =
      repo().insert(struct!(Client, [kind: "cimd", client_id: client_id] ++ fields),
        on_conflict: update,
        conflict_target: :client_id
      )

    case get_by_client_id(client_id) do
      %Client{kind: "cimd"} = client -> {:ok, client}
      _other -> {:error, :unknown_client}
    end
  end

  @doc "A client by its row uuid; `nil` for an unknown or malformed uuid."
  @spec get(term()) :: Client.t() | nil
  def get(uuid) when is_binary(uuid) do
    if UUIDUtils.valid?(uuid), do: repo().get(Client, uuid), else: nil
  end

  def get(_uuid), do: nil

  @doc """
  A client by the `client_id` it presents; `nil` when unknown, and for text the table cannot hold
  (a NUL byte, bytes that are not UTF-8), which no client has and which must not reach the query.
  """
  @spec get_by_client_id(term()) :: Client.t() | nil
  def get_by_client_id(client_id) when is_binary(client_id) do
    if Input.valid?(client_id),
      do: repo().one(from(c in Client, where: c.client_id == ^client_id)),
      else: nil
  end

  def get_by_client_id(_client_id), do: nil

  defp repo, do: RepoHelper.repo()
end
