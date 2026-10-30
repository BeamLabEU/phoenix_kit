defmodule PhoenixKit.Modules.Storage.Libraries.Preferences do
  @moduledoc """
  Library identity and audience settings, shared by the owner's and administrator's UI.
  Changes are validated against a fresh locked row; expanding or restricting access and
  changing an address require explicit confirmation. No storage objects are moved.
  """
  import Ecto.Query
  alias PhoenixKit.Activity
  alias PhoenixKit.Modules.Storage.Library
  alias PhoenixKit.PubSub.Manager
  alias PhoenixKit.Users.Auth.Scope

  def access_mode(%Library{visibility: "site"} = library) do
    if library.settings["public_audience"] == "authenticated",
      do: "authenticated",
      else: "anonymous"
  end

  def access_mode(_library), do: "private"

  @doc "Whether this scope may change the library's identity and access settings."
  def can_manage?(%Scope{} = scope, %Library{kind: "user", trashed_at: nil} = library) do
    Scope.system_role?(scope) or Scope.user_uuid(scope) == to_string(library.owner_uuid)
  end

  def can_manage?(_scope, _library), do: false

  @doc "Whether this owner may expand a library's audience under the host publication policy."
  def can_publish?(scope, library) do
    can_manage?(scope, library) and
      (Scope.system_role?(scope) or
         Application.get_env(:phoenix_kit, :library_owner_publication, false) or
         Scope.can?(scope, "storage.public_library"))
  end

  @doc """
  Saves string-keyed name, slug and access attributes under a row lock.
  Address and audience changes require `"confirm" => "true"`. Expanding an audience
  also requires the publication permission or the host's owner-publication policy.
  """
  def update(%Scope{} = scope, uuid, attrs) when is_map(attrs) do
    repo = PhoenixKit.RepoHelper.repo()

    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} ->
        repo.transaction(fn ->
          library = repo.one(from l in Library, where: l.uuid == ^uuid, lock: "FOR UPDATE")
          unless can_manage?(scope, library), do: repo.rollback(:not_allowed)
          {mode, slug} = validate_change!(repo, scope, library, attrs)

          settings =
            library.settings
            |> Map.put(
              "public_audience",
              if(mode == "authenticated", do: "authenticated", else: "anonymous")
            )
            |> remember_slug(library.slug, slug)
            |> rotate_access_revision(access_mode(library), mode)

          changeset =
            library
            |> Library.rename_changeset(%{"name" => Map.get(attrs, "name", library.name)})
            |> Library.slug_changeset(%{"slug" => slug})
            |> Ecto.Changeset.change(
              visibility: if(mode == "private", do: "private", else: "site"),
              settings: settings
            )

          case repo.update(changeset) do
            {:ok, updated} ->
              Activity.log("storage", "storage.library.settings_changed",
                actor_uuid: Scope.user_uuid(scope),
                resource_type: "library",
                resource_uuid: updated.uuid,
                metadata: %{
                  "name" => updated.name,
                  "slug" => updated.slug,
                  "previous_access" => access_mode(library),
                  "access" => mode
                }
              )

              updated

            {:error, changeset} ->
              repo.rollback(changeset)
          end
        end)
        |> tap(fn
          {:ok, library} ->
            Manager.broadcast(
              "storage:library_settings",
              {:library_settings_changed, library.uuid}
            )

          _ ->
            :ok
        end)

      _ ->
        {:error, :not_allowed}
    end
  end

  def update(_scope, _uuid, _attrs), do: {:error, :not_allowed}

  defp validate_change!(repo, scope, library, attrs) do
    mode = Map.get(attrs, "access", access_mode(library))
    unless mode in ~w(private authenticated anonymous), do: repo.rollback(:invalid_access)

    if access_rank(mode) > access_rank(access_mode(library)) and
         not can_publish?(scope, library),
       do: repo.rollback(:publishing_not_allowed)

    slug = Map.get(attrs, "slug", library.slug)
    changed? = mode != access_mode(library) or slug != library.slug
    if changed? and attrs["confirm"] != "true", do: repo.rollback(:confirmation_required)

    {mode, slug}
  end

  defp access_rank("private"), do: 0
  defp access_rank("authenticated"), do: 1
  defp access_rank("anonymous"), do: 2

  defp rotate_access_revision(settings, previous, current) when previous != current,
    do: Map.put(settings, "access_revision", Ecto.UUID.generate())

  defp rotate_access_revision(settings, _previous, _current), do: settings

  defp remember_slug(settings, old, new) when old != new do
    Map.update(settings, "previous_slugs", [old], &Enum.uniq([old | &1]))
  end

  defp remember_slug(settings, _old, _new), do: settings
end
