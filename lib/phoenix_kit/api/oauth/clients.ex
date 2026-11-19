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

  require Logger

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.API.OAuth.Cimd
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.ClientPolicy
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Input
  alias PhoenixKit.API.OAuth.Limits
  alias PhoenixKit.API.OAuth.RedirectUri
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  @max_name_length 160
  # What shows nothing on screen: control, format, line and paragraph separators, and the letters
  # and marks that are blank (Hangul fillers, Khmer inherent vowels, the combining grapheme joiner,
  # the Braille blank).
  @invisible ~r/[\p{C}\p{Zl}\p{Zp}\x{115F}\x{1160}\x{17B4}\x{17B5}\x{034F}\x{2800}\x{3164}\x{FFA0}]/u

  @doc """
  Registers a client an administrator named: `attrs` takes `client_id` (required, unique, at most
  2048 characters), `client_name` (made safe by `clean_name/1`), `client_uri` and `redirect_uris`.

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
    |> Ecto.Changeset.update_change(:client_name, &clean_name/1)
    |> Ecto.Changeset.validate_length(:client_id, max: 2048)
    |> validate_storable([:client_id, :client_uri])
    |> Ecto.Changeset.validate_change(:redirect_uris, fn :redirect_uris, uris ->
      if Enum.all?(uris, &RedirectUri.valid?/1),
        do: [],
        else: [redirect_uris: "must be https or loopback http URIs without fragment or wildcard"]
    end)
    |> Ecto.Changeset.unique_constraint(:client_id)
    |> repo().insert()
  end

  # A NUL byte or bytes that are not UTF-8 cannot be stored: a changeset error, not a raised
  # database error. (The name is not here: `clean_name/1` strips what it cannot keep.)
  defp validate_storable(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      Ecto.Changeset.validate_change(acc, field, fn _field, value ->
        if Input.valid?(value), do: [], else: [{field, "must be valid text"}]
      end)
    end)
  end

  @doc """
  A client's own name made safe to store and show: control, format and line-separator characters
  and the invisible fillers (the Hangul fillers, the Braille blank, the Khmer inherent vowels, the
  combining grapheme joiner) removed, any run of spaces (also the ideographic and the no-break
  one) made one space, trimmed, cut to 160 characters and to 160 code points (the size of the
  column). `nil` when what is left is empty or `name` is not valid text.
  """
  @spec clean_name(term()) :: String.t() | nil
  def clean_name(name) when is_binary(name) do
    if String.valid?(name), do: clean_valid_name(name), else: nil
  end

  def clean_name(_name), do: nil

  defp clean_valid_name(name) do
    cleaned =
      name
      |> String.replace(@invisible, "")
      |> String.replace(~r/\p{Zs}+/u, " ")
      |> String.trim()
      |> cut_name(@max_name_length)
      |> String.trim()

    if cleaned == "", do: nil, else: cleaned
  end

  @doc """
  `text` cut to at most `max_graphemes` characters as a person counts them and at most 160 code
  points, the size of the columns that hold a name (a name of combining marks has far more code
  points than graphemes). Whole graphemes only, so a mark is never left without its letter.
  """
  @spec cut_name(String.t(), pos_integer()) :: String.t()
  def cut_name(text, max_graphemes) when is_binary(text) and max_graphemes > 0 do
    {_points, kept} =
      text
      |> String.graphemes()
      |> Enum.take(max_graphemes)
      |> Enum.reduce_while({0, []}, fn grapheme, {points, kept} ->
        points = points + length(String.to_charlist(grapheme))

        if points <= @max_name_length,
          do: {:cont, {points, [grapheme | kept]}},
          else: {:halt, {points, kept}}
      end)

    kept |> Enum.reverse() |> IO.iodata_to_binary()
  end

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
      returned as it is: the switch of Dynamic Client Registration (`api_oauth_dcr_enabled`)
      governs new registrations only, a client registered while it was on keeps working (the
      client policy still judges it; deleting the client ends it);
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
    if Input.valid?(client_id),
      do: resolve_valid(client_id, opts),
      else: {:error, :unknown_client}
  end

  def resolve(_client_id, _opts), do: {:error, :unknown_client}

  defp resolve_valid(client_id, opts) do
    case get_by_client_id(client_id) do
      %Client{kind: "cimd"} = row -> cached_or_fetch(row, opts)
      %Client{} = client -> allowed(client)
      nil -> fetch_new(client_id, opts)
    end
  end

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

  defp allowed(%Client{} = client),
    do: if(allowed?(client), do: {:ok, client}, else: {:error, :not_allowed})

  @doc """
  Whether the client policy (`PhoenixKit.API.OAuth.ClientPolicy`) lets `client` be used now. The
  consent screen and the token endpoint ask it again at every step.
  """
  @spec allowed?(Client.t()) :: boolean()
  def allowed?(%Client{} = client),
    do: ClientPolicy.allowed?(client.kind, client.client_id, client.redirect_uris)

  # A document on the authorization server's own host is no client, whether it is new or its row
  # has run out: nothing is counted and nothing is fetched.
  defp fetch(client_id, opts) do
    with :ok <- not_own_host(client_id),
         :ok <- host_allowed(client_id, []),
         :ok <- not_busy(),
         :ok <- within_limits(client_id, opts[:ip]),
         {:ok, document} <- fetch_document(client_id),
         :ok <- host_allowed(client_id, document.redirect_uris) do
      store(client_id, document)
    end
  end

  defp not_own_host(client_id),
    do: if(Cimd.own_host?(client_id), do: {:error, :unknown_client}, else: :ok)

  # Asked before the limits are counted: no place to fetch in is not the asker's doing.
  defp not_busy, do: if(Cimd.busy?(), do: {:error, :busy}, else: :ok)

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
      {:ok, document} ->
        {:ok, document}

      {:error, :busy} ->
        {:error, :busy}

      {:error, reason} ->
        # Why it failed, so an operator can tell a secret in the document from a blocked host
        # from a body that is not JSON: the reason only, never the URL or what the server sent.
        Logger.info("[OAuth] a client metadata document was refused: #{reason_label(reason)}")
        {:error, :fetch_failed}
    end
  end

  # The words of a reason (`{:fetch_failed, {:http_status, 404}}` is "fetch_failed http_status
  # 404"): atoms and integers only, anything else is "?".
  defp reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_label(reason) when is_integer(reason), do: Integer.to_string(reason)

  defp reason_label(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.map_join(" ", &reason_label/1)

  defp reason_label(_reason), do: "?"

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

  @doc """
  Removes a client (a `Client` or its row uuid) and ends every grant of it first.

  The tables would take the grants and their tokens with the client (`ON DELETE CASCADE`) and
  leave the hidden keys of those grants behind, alive. So each grant goes through
  `PhoenixKit.API.OAuth.Grants.revoke/2` (the lock order key, grant, tokens; reason
  `"client_deleted"`; one `oauth.grant_revoked` entry each), and only then is the client deleted,
  all in one transaction: if a grant cannot be ended, the client stays. `opts`: `:actor_uuid`, who
  deletes, for the activity entries.

  Returns `{:ok, client}`, or `{:error, :not_found}` for a client that is not there.
  """
  @spec delete(Client.t() | String.t() | nil, keyword()) ::
          {:ok, Client.t()} | {:error, :not_found | term()}
  def delete(client_or_uuid, opts \\ [])

  def delete(%Client{uuid: uuid}, opts), do: delete(uuid, opts)

  def delete(uuid, opts) when is_binary(uuid) do
    case get(uuid) do
      %Client{} = client -> remove(client, opts)
      nil -> {:error, :not_found}
    end
  end

  def delete(_client, _opts), do: {:error, :not_found}

  defp remove(%Client{uuid: uuid}, opts) do
    revoke_opts = [reason: "client_deleted", actor_uuid: opts[:actor_uuid]]

    repo().transaction(fn ->
      # A consent that is making a grant of this client either commits first (its grant is then
      # read and ended below) or waits here and fails on the foreign key once the client is gone:
      # never a grant that outlives its client.
      case repo().one(from(c in Client, where: c.uuid == ^uuid, lock: "FOR UPDATE")) do
        %Client{} = locked ->
          end_grants(locked, revoke_opts)
          repo().delete(locked) |> unwrap()

        nil ->
          repo().rollback(:not_found)
      end
    end)
  end

  defp end_grants(%Client{uuid: uuid}, revoke_opts) do
    from(g in Grant, where: g.client_uuid == ^uuid, select: g.uuid, order_by: g.inserted_at)
    |> repo().all()
    |> Enum.each(fn grant_uuid ->
      case Grants.revoke(grant_uuid, revoke_opts) do
        {:ok, _grant} -> :ok
        {:error, :not_found} -> :ok
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  defp unwrap({:ok, client}), do: client
  defp unwrap({:error, changeset}), do: repo().rollback(changeset)

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
