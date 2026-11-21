defmodule PhoenixKit.Modules.Storage.CDN do
  @moduledoc """
  CDN delivery preferences. Connections are selected by their integration UUID.
  A checked rendition expresses an owner's preference; serving it also requires
  an authorized reader, a verified origin and an adapter for that audience.
  """
  import Ecto.Query
  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Storage.{Libraries, Library, VariantSets}
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope

  @site_key "storage_cdn_connection"
  @library_key "cdn_delivery"

  def site_connection do
    if Settings.get_setting(@site_key, "off") == "bucket", do: "bucket", else: "off"
  end

  def connections(owner), do: Integrations.connected_choices(:cdn_delivery, owner)

  def save_site(scope, selection) do
    with :ok <- manage_site(scope),
         true <- selection in ["off", "bucket"] do
      Settings.update_setting(@site_key, selection, actor_uuid: Scope.user_uuid(scope))
    else
      false -> {:error, :invalid_connection}
      error -> error
    end
  end

  def site_renditions(set_uuid) do
    Settings.get_json_setting_cached("storage_cdn_renditions_" <> set_uuid, %{})["public"] || []
  end

  def save_site_renditions(scope, set_uuid, ids) do
    with :ok <- manage_site(scope),
         %{} <- VariantSets.get_variant_set(set_uuid),
         {:ok, public} <- validate_ids(set_uuid, ids) do
      Settings.update_json_setting("storage_cdn_renditions_" <> set_uuid, %{"public" => public},
        actor_uuid: Scope.user_uuid(scope)
      )
    else
      nil -> {:error, :invalid_profile}
      error -> error
    end
  end

  def rows(set_uuid) do
    dimensions = VariantSets.list_dimensions(set_uuid)

    for(d <- dimensions, d.enabled, d.name != "original", do: {d.uuid, d.name}) ++
      [{"original", "original"}]
  end

  def preferences(%Library{settings: settings}) do
    Map.merge(
      %{"connection" => "inherit", "mode" => "inherit", "public" => []},
      (settings || %{})[@library_key] || %{}
    )
    |> Map.update!("connection", fn
      mode when mode in ["inherit", "bucket", "off"] -> mode
      _legacy_zone -> "off"
    end)
  end

  def owner?(scope, %Library{owner_uuid: id, trashed_at: nil}) when is_binary(id),
    do: Scope.user_uuid(scope) == id

  def owner?(scope, %Library{kind: "system", trashed_at: nil}), do: manage_site(scope) == :ok
  def owner?(_, _), do: false

  def personal_connections(%Library{owner_uuid: id}) when is_binary(id),
    do: connections({:user, id})

  def personal_connections(_), do: []

  def save_library(scope, library_uuid, attrs) when is_map(attrs) do
    repo = RepoHelper.repo()

    repo.transaction(fn ->
      library = repo.one(from l in Library, where: l.uuid == ^library_uuid, lock: "FOR UPDATE")

      with :ok <- Libraries.check_managed(library),
           true <- owner?(scope, library),
           %{"connection" => selection, "mode" => mode} when mode in ["inherit", "custom"] <-
             attrs,
           true <- selection in ["off", "inherit", "bucket"],
           {:ok, ids} <-
             validate_ids(VariantSets.set_uuid_for(library), Map.get(attrs, "public", [])) do
        policy = %{
          "connection" => selection,
          "mode" => mode,
          "public" => if(mode == "custom", do: ids, else: [])
        }

        library
        |> Ecto.Changeset.change(settings: Map.put(library.settings || %{}, @library_key, policy))
        |> repo.update!()
      else
        {:error, :managed} -> repo.rollback(:managed)
        _ -> repo.rollback(:invalid_selection)
      end
    end)
  end

  defp validate_ids(set_uuid, ids) when is_list(ids) do
    allowed = MapSet.new(rows(set_uuid), &elem(&1, 0))

    if Enum.all?(ids, &MapSet.member?(allowed, &1)),
      do: {:ok, Enum.uniq(ids)},
      else: {:error, :invalid_rendition}
  end

  defp validate_ids(_, _), do: {:error, :invalid_rendition}

  defp manage_site(%Scope{} = scope) do
    if Scope.has_module_access?(scope, "media.manage"), do: :ok, else: {:error, :not_allowed}
  end

  defp manage_site(_), do: {:error, :not_allowed}
end
