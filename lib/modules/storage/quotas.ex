defmodule PhoenixKit.Modules.Storage.Quotas do
  @moduledoc """
  How much of the site's storage an account uses, how much it may use, and the
  check an upload passes before it is stored.

  ## What counts

  An account is charged for the user libraries it **owns** (`kind: "user"`,
  `owner_uuid`), whoever uploaded the files: a contributor's upload counts for
  the library's owner, who chose to let them in and keeps the files when they
  leave. Per file it counts what the site keeps for it:

    * `originals` — the uploaded files (`File.size`);
    * `renditions` — the sizes made from them (every `FileInstance` but the
      `original`) and the tiles of zoomable images (system-managed files).

  Each object is counted once: the copies a storage profile keeps of it (a
  second disk, an off-site backup) are the site's cost, not the account's.
  Trashed files still count until they are purged, because they are still
  stored. Libraries kept on the owner's **own** storage (a V206 user profile)
  do not count at all.

  ## The limit

  `limit/1` is, in bytes, nil for no limit:

    * the host's own answer when it configures one, for plans that differ by
      account:

          config :phoenix_kit, :storage_quota, {MyApp.Plans, :storage_bytes}

      called with the owner's uuid; it returns bytes, `nil` (no limit) or
      `:default` (use the site setting);
    * otherwise the `storage_user_quota_mb` setting (Settings → Media →
      Libraries, "Storage per user"), `0` or unset for no limit.

  ## The check

  `check_upload/2` refuses a new file that would take the owner over the
  limit (`{:error, :quota_exceeded}`). It counts the original only, since the
  sizes are not made yet, so they may take an account slightly past its limit;
  two uploads at the same moment may do the same. Neither is refused
  afterwards: the next upload is. `Storage.store_file_in_buckets/7` calls it
  for every new file in a library; an upload the uploader already has (a
  duplicate) costs nothing and is never refused. Nothing already stored is
  ever removed for being over the limit.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.{FileInstance, Library, StorageProfile}
  alias PhoenixKit.Settings

  @setting "storage_user_quota_mb"
  @mb 1024 * 1024

  @type usage :: %{
          originals: non_neg_integer(),
          renditions: non_neg_integer(),
          total: non_neg_integer()
        }

  @doc "The setting that holds the site-wide limit, in MB (`0` for none)."
  @spec setting_key() :: String.t()
  def setting_key, do: @setting

  @doc "The site-wide limit in MB, nil for none (`storage_user_quota_mb` at `0` or unset)."
  @spec site_limit_mb() :: pos_integer() | nil
  def site_limit_mb do
    case Integer.parse(to_string(Settings.get_setting(@setting, ""))) do
      {mb, ""} when mb > 0 -> mb
      _ -> nil
    end
  end

  @doc """
  The bytes `owner_uuid` may keep on the site's storage, nil for no limit:
  the host's `:storage_quota` answer, else the site setting.
  """
  @spec limit(String.t()) :: non_neg_integer() | nil
  def limit(owner_uuid) when is_binary(owner_uuid) do
    case host_limit(owner_uuid) do
      :default -> site_limit()
      bytes when is_integer(bytes) and bytes >= 0 -> bytes
      nil -> nil
      _other -> site_limit()
    end
  end

  defp site_limit do
    case site_limit_mb() do
      nil -> nil
      mb -> mb * @mb
    end
  end

  defp host_limit(owner_uuid) do
    case Application.get_env(:phoenix_kit, :storage_quota) do
      {module, function} when is_atom(module) and is_atom(function) ->
        apply(module, function, [owner_uuid])

      fun when is_function(fun, 1) ->
        fun.(owner_uuid)

      _ ->
        :default
    end
  end

  @doc """
  What `owner_uuid`'s libraries on the site's storage hold, in bytes:
  `%{originals:, renditions:, total:}` (see the moduledoc for what counts).
  Two queries.
  """
  @spec usage(String.t()) :: usage()
  def usage(owner_uuid) when is_binary(owner_uuid) do
    files = from(f in StorageFile, where: f.library_uuid in subquery(charged(owner_uuid)))

    {originals, tiles} =
      from(f in files,
        select:
          {coalesce(sum(fragment("CASE WHEN ? THEN 0 ELSE ? END", f.system_managed, f.size)), 0),
           coalesce(sum(fragment("CASE WHEN ? THEN ? ELSE 0 END", f.system_managed, f.size)), 0)}
      )
      |> repo().one()

    sizes =
      from(i in FileInstance,
        join: f in subquery(files),
        on: f.uuid == i.file_uuid,
        where: f.system_managed == false and i.variant_name != "original",
        select: coalesce(sum(i.size), 0)
      )
      |> repo().one()

    originals = to_integer(originals)
    renditions = to_integer(tiles) + to_integer(sizes)
    %{originals: originals, renditions: renditions, total: originals + renditions}
  end

  # The libraries an owner is charged for: their user libraries, trashed ones
  # included until purged, except those on their own storage.
  defp charged(owner_uuid) do
    from(l in Library,
      left_join: p in StorageProfile,
      on: p.uuid == l.storage_profile_uuid,
      where: l.kind == "user" and l.owner_uuid == ^owner_uuid and is_nil(p.owner_uuid),
      select: l.uuid
    )
  end

  @doc """
  `owner_uuid`'s usage and limit together, for a page that shows them:
  `%{usage: usage(), limit: bytes | nil, over?: boolean}`.
  """
  @spec status(String.t()) :: %{usage: usage(), limit: non_neg_integer() | nil, over?: boolean()}
  def status(owner_uuid) when is_binary(owner_uuid) do
    usage = usage(owner_uuid)
    limit = limit(owner_uuid)
    %{usage: usage, limit: limit, over?: is_integer(limit) and usage.total >= limit}
  end

  @doc """
  Whether a new file of `bytes` may go into the library `library_uuid`: `:ok`,
  or `{:error, :quota_exceeded}` when its owner has a limit and the file would
  take them past it. A library that is not a user library, has no owner, or is
  on its owner's own storage is never limited.
  """
  @spec check_upload(String.t() | nil, non_neg_integer()) :: :ok | {:error, :quota_exceeded}
  def check_upload(nil, _bytes), do: :ok

  def check_upload(library_uuid, bytes) when is_binary(library_uuid) and is_integer(bytes) do
    with owner when is_binary(owner) <- charged_owner(library_uuid),
         limit when is_integer(limit) <- limit(owner) do
      if usage(owner).total + bytes > limit, do: {:error, :quota_exceeded}, else: :ok
    else
      _ -> :ok
    end
  end

  # The owner a library's uploads are charged to, nil when they are not.
  defp charged_owner(library_uuid) do
    from(l in Library,
      left_join: p in StorageProfile,
      on: p.uuid == l.storage_profile_uuid,
      where:
        l.uuid == ^library_uuid and l.kind == "user" and not is_nil(l.owner_uuid) and
          is_nil(p.owner_uuid),
      select: l.owner_uuid
    )
    |> repo().one()
    |> case do
      nil -> nil
      owner -> to_string(owner)
    end
  end

  defp to_integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(nil), do: 0

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
