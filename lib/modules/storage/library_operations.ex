defmodule PhoenixKit.Modules.Storage.LibraryOperations do
  @moduledoc """
  Personal library jobs. Reads are limited to current library members; only the
  owner may start or control verification and copying. The active session role
  is refreshed for every read and action. This boundary deliberately grants no
  access to global Jobs or to other kinds of storage maintenance.
  """
  import Ecto.Query

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Jobs.Engine
  alias PhoenixKit.Jobs.Run
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Jobs.Reconcile
  alias PhoenixKit.Modules.Storage.Jobs.VerifyLibrary
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.Library
  alias PhoenixKit.Modules.Storage.VerificationPolicy
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  @kinds ["storage.reconcile", "storage.verify_library"]
  @page_size 20

  @doc "Libraries whose operations this person may read, with fresh access checks."
  def libraries(scope) do
    scope = fresh_scope(scope)

    if Libraries.may_use_libraries?(scope),
      do: Libraries.list_user_libraries(Scope.user_uuid(scope)),
      else: []
  end

  @doc "A page of library operations; active ones first, then newest first."
  def list(scope, page \\ 1) do
    entries = libraries(scope)
    uuids = Enum.map(entries, & &1.library.uuid)
    page = max(page, 1)

    query =
      from(r in Run,
        where: r.scope_type == "library" and r.scope_uuid in ^uuids and r.kind in ^@kinds
      )

    total = repo().aggregate(query, :count)
    page = min(page, max(1, ceil(total / @page_size)))

    runs =
      query
      |> order_by([r],
        desc: fragment("? = ANY(?)", r.state, ^Run.active_states()),
        desc: r.inserted_at,
        desc: r.uuid
      )
      |> limit(^@page_size)
      |> offset(^((page - 1) * @page_size))
      |> repo().all()

    %{
      runs: runs,
      libraries: entries,
      page: page,
      pages: max(1, ceil(total / @page_size)),
      total: total
    }
  end

  @doc "An authorized run or nil; arbitrary run UUIDs never expose job history."
  def get(scope, uuid) do
    with %Run{scope_type: "library", kind: kind} = run <- PhoenixKit.Jobs.get_run(uuid),
         true <- kind in @kinds,
         true <- Enum.any?(libraries(scope), &(&1.library.uuid == run.scope_uuid)) do
      run
    else
      _ -> nil
    end
  end

  @doc "Starts a read-only verification of the owner's library."
  def verify(scope, uuid, params) do
    with {:ok, scope, library} <- owner(scope, uuid),
         mode when mode in ["presence", "checksum"] <- params["mode"] || "presence" do
      # A fixed upper bound excludes later uploads without loading file IDs.
      last =
        repo().one(
          from(f in StorageFile,
            where: f.library_uuid == ^library.uuid,
            order_by: [desc: f.uuid],
            limit: 1,
            select: f.uuid
          )
        )

      Engine.start(VerifyLibrary, {"library", library.uuid},
        actor_uuid: Scope.user_uuid(scope),
        mode: "manual",
        args: %{
          "mode" => mode,
          "include_previews" => params["include_previews"] in [true, "true", "on"],
          "through" => last
        }
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_options}
    end
  end

  @doc "Controls allowed by the run's state for its current library owner."
  def controls(scope, %Run{} = run) do
    case owner(scope, run.scope_uuid) do
      {:ok, _, library} ->
        offered = if run.kind in @kinds, do: state_controls(run.state), else: []

        if run.kind == VerifyLibrary.kind() and "retry" in offered and
             VerificationPolicy.next_allowed_for([library])[library.uuid],
           do: List.delete(offered, "retry"),
           else: offered

      _ ->
        []
    end
  end

  @doc "Pause, resume, cancel or retry an authorized library operation."
  def control(scope, uuid, action) do
    with %Run{} = run <- get(scope, uuid),
         {:ok, scope, _library} <- owner(scope, run.scope_uuid),
         true <- action in state_controls(run.state) do
      actor = Scope.user_uuid(scope)

      case action do
        "retry" ->
          kind = if run.kind == Reconcile.kind(), do: Reconcile, else: VerifyLibrary

          Engine.start(kind, {"library", run.scope_uuid},
            args: Map.delete(run.args, "retry_of"),
            retry_of: run.uuid,
            actor_uuid: actor,
            mode: "manual"
          )

        "pause" ->
          Engine.transition(run.uuid, {:pause, actor}, actor_uuid: actor, mode: "manual")

        "resume" ->
          Engine.transition(run.uuid, {:resume, actor}, actor_uuid: actor, mode: "manual")

        "cancel" ->
          Engine.transition(run.uuid, {:cancel, actor}, actor_uuid: actor, mode: "manual")
      end
    else
      _ -> {:error, :not_allowed}
    end
  end

  @doc "Paginated, durable lifecycle and batch logs, resolving names only after authorization."
  def logs(scope, uuid, page \\ 1) do
    case get(scope, uuid) do
      nil ->
        nil

      run ->
        query =
          from(e in Entry, where: e.resource_type == "job_run" and e.resource_uuid == ^run.uuid)

        total = repo().aggregate(query, :count)
        pages = max(1, ceil(total / @page_size))
        page = min(max(page, 1), pages)

        entries =
          repo().all(
            from(e in query,
              order_by: [desc: e.inserted_at, desc: e.uuid],
              limit: ^@page_size,
              offset: ^((page - 1) * @page_size),
              preload: [:actor]
            )
          )

        %{
          run: run,
          entries: entries,
          names: names(entries, run.scope_uuid),
          page: page,
          pages: pages,
          total: total
        }
    end
  end

  defp names(entries, library_uuid) do
    problems = Enum.flat_map(entries, &((&1.metadata || %{})["problems"] || []))
    files = for p <- problems, uuid = p["file_uuid"], do: uuid
    buckets = for p <- problems, uuid = p["bucket_uuid"], do: uuid
    library = Libraries.get_library(library_uuid)

    %{
      files:
        Map.new(
          repo().all(
            from(f in StorageFile,
              where: f.uuid in ^files and f.library_uuid == ^library_uuid,
              select: {f.uuid, coalesce(f.original_file_name, f.file_name)}
            )
          )
        ),
      buckets:
        Map.new(
          repo().all(
            from(b in Bucket,
              where:
                b.uuid in ^buckets and
                  (is_nil(b.owner_uuid) or b.owner_uuid == ^library.owner_uuid),
              select: {b.uuid, coalesce(b.bucket_name, b.name)}
            )
          )
        )
    }
  end

  defp owner(scope, uuid) do
    scope = fresh_scope(scope)

    with true <- Libraries.may_use_libraries?(scope),
         %Library{kind: "user", trashed_at: nil} = library <- Libraries.get_library(uuid),
         :owner <- Libraries.role(library, Scope.user_uuid(scope)) do
      {:ok, scope, library}
    else
      _ -> {:error, :not_allowed}
    end
  end

  defp fresh_scope(%Scope{user: %{active_role_uuid: role}} = scope) do
    case Auth.get_user(Scope.user_uuid(scope)) do
      %{is_active: true, api_only: false} = user ->
        Scope.for_user(%{user | active_role_uuid: role})

      _ ->
        nil
    end
  end

  defp fresh_scope(_scope), do: nil

  defp state_controls(state) when state in ~w(queued running), do: ~w(pause cancel)
  defp state_controls("pausing"), do: ["cancel"]
  defp state_controls("paused"), do: ~w(resume cancel)
  defp state_controls(state) when state in ~w(failed cancelled), do: ["retry"]
  defp state_controls(_state), do: []
  defp repo, do: PhoenixKit.RepoHelper.repo()
end
