defmodule PhoenixKit.Modules.Storage.LibraryOperationsTest do
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Jobs
  alias PhoenixKit.Jobs.{Engine, History, RunWorker}
  alias PhoenixKit.Modules.Storage

  alias PhoenixKit.Modules.Storage.{
    Bucket,
    FileInstance,
    FileLocation,
    Libraries,
    LibraryOperations,
    LibraryVerification,
    Profiles,
    VerificationPolicy
  }

  alias PhoenixKit.Modules.Storage.Jobs.{Reconcile, VerifyLibrary}
  alias PhoenixKit.Modules.Storage.Providers.Local
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKit.Users.Auth.Scope

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    start_supervised!({Oban, name: Oban, repo: Repo, testing: :manual, queues: [], plugins: []})
    {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{name: "Verify #{n}"})

    for key <- ~w(storage storage.create_library),
        do: Permissions.grant_permission(role.uuid, key)

    user = user!(role)
    other = user!(role)

    {:ok, library} =
      Libraries.create_user_library(Scope.for_user(user), %{"name" => "Private verification #{n}"})

    {:ok, other_library} =
      Libraries.create_user_library(Scope.for_user(other), %{"name" => "Other library #{n}"})

    Repo.update_all(Bucket, set: [enabled: false])

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "verification-#{n}",
        provider: "local",
        endpoint: Path.join(tmp, "bucket"),
        enabled: true
      })

    profile = Profiles.default_profile()
    {:ok, _} = Profiles.put_bucket(profile, bucket.uuid, %{role: "primary"})

    {:ok, _} =
      Profiles.update_profile(Profiles.default_profile(), %{copies_local: 1, copies_cloud: 0})

    :persistent_term.erase(:phoenix_kit_buckets_cache)
    on_exit(fn -> :persistent_term.erase(:phoenix_kit_buckets_cache) end)

    %{
      user: user,
      other: other,
      library: library,
      other_library: other_library,
      bucket: bucket,
      tmp: tmp,
      role: role
    }
  end

  defp user!(role) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "verify-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.assign_role(user, role.name)
    Repo.get!(Auth.User, user.uuid)
  end

  defp upload!(ctx, name \\ "original.txt", library \\ nil) do
    content = "original bytes #{name}"
    path = Path.join(ctx.tmp, name)
    File.write!(path, content)
    sha = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(path, "document", ctx.user.uuid, sha, "txt", name,
        library_uuid: (library || ctx.library).uuid
      )

    {:ok, file} = Storage.update_file(file, %{status: "active"})
    file
  end

  defp start!(ctx, params \\ %{}) do
    assert {:ok, run, :started} =
             LibraryOperations.verify(Scope.for_user(ctx.user), ctx.library.uuid, params)

    run
  end

  defp age_verification!(run) do
    old = DateTime.utc_now() |> DateTime.add(-31 * 86_400, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(r in PhoenixKit.Jobs.Run, where: r.uuid == ^run.uuid),
      set: [inserted_at: old]
    )

    library = Libraries.get_library(run.scope_uuid)

    Repo.update_all(from(l in Storage.Library, where: l.uuid == ^library.uuid),
      set: [
        settings:
          Map.put(library.settings, "verification_last_started_at", DateTime.to_iso8601(old))
      ]
    )
  end

  defp batch!(run) do
    assert {:ok, claimed, token} = Engine.claim(run.uuid, run.generation)
    outcome = RunWorker.batch_outcome(VerifyLibrary, claimed, true)
    assert {:ok, updated} = Engine.checkpoint(run.uuid, token, outcome, dispatch: false)
    updated
  end

  test "presence and deep verification read local originals without changing location health",
       ctx do
    file = upload!(ctx)
    before = Repo.all(from(l in FileLocation, order_by: l.uuid))
    assert LibraryVerification.check(file, "presence", false) == []
    assert LibraryVerification.check(file, "checksum", false) == []
    assert Repo.all(from(l in FileLocation, order_by: l.uuid)) == before
    instance = Storage.get_file_instance_by_name(file.uuid, "original")
    path = Path.join(Local.root(ctx.bucket), instance.file_name)
    File.write!(path, String.duplicate("x", instance.size))

    assert [%{"problem" => "checksum_mismatch", "bucket_uuid" => uuid}] =
             LibraryVerification.check(file, "checksum", false)

    assert uuid == ctx.bucket.uuid
    assert LibraryVerification.check(file, "presence", false) == []
    File.rm!(path)

    assert [%{"problem" => "missing_or_inaccessible"}] =
             LibraryVerification.check(file, "presence", false)

    assert Repo.all(from(l in FileLocation, order_by: l.uuid)) == before
  end

  test "previews are opt-in, missing originals and required copies are findings", ctx do
    file = upload!(ctx)
    original = Storage.get_file_instance_by_name(file.uuid, "original")

    {:ok, _preview} =
      Storage.create_file_instance(%{
        file_uuid: file.uuid,
        variant_name: "thumbnail",
        file_name: "missing-preview.jpg",
        mime_type: "image/jpeg",
        ext: "jpg",
        checksum: "abcd",
        size: 10,
        processing_status: "completed"
      })

    assert LibraryVerification.check(file, "presence", false) == []

    assert Enum.any?(
             LibraryVerification.check(file, "presence", true),
             &(&1["rendition"] == "thumbnail" and &1["problem"] == "no_copy")
           )

    Repo.delete_all(from(l in FileLocation, where: l.file_instance_uuid == ^original.uuid))
    findings = LibraryVerification.check(file, "presence", false)
    assert Enum.any?(findings, &(&1["problem"] == "insufficient_copies"))
    Repo.delete!(original)

    assert [%{"problem" => "missing", "rendition" => "original"}] =
             LibraryVerification.check(file, "presence", false)
  end

  test "provider errors and missing checksums are safe findings", ctx do
    file = upload!(ctx)

    findings =
      LibraryVerification.check(file, "checksum", false,
        checksum: fn _, _ -> {:error, "secret-value"} end
      )

    assert [%{"problem" => "read_failed"}] = findings
    refute inspect(findings) =~ "secret-value"

    Repo.update_all(from(i in FileInstance, where: i.file_uuid == ^file.uuid),
      set: [checksum: ""]
    )

    file = %{file | file_checksum: nil}

    assert [%{"problem" => "unrecorded_checksum"}] =
             LibraryVerification.check(file, "checksum", false)
  end

  test "legacy checksums are inconclusive rather than mistaken for corruption", ctx do
    file = upload!(ctx)

    Repo.update_all(from(i in FileInstance, where: i.file_uuid == ^file.uuid),
      set: [checksum: String.duplicate("a", 32)]
    )

    assert [%{"problem" => "unsupported_checksum"}] =
             LibraryVerification.check(file, "checksum", false)
  end

  test "trash and generated children are excluded, failed originals are checked, and processing is inconclusive",
       ctx do
    original = upload!(ctx)
    trashed = upload!(ctx, "trash.txt")
    managed = upload!(ctx, "managed.txt")
    failed = upload!(ctx, "failed.txt")
    processing = upload!(ctx, "processing.txt")

    Repo.update_all(from(f in Storage.File, where: f.uuid == ^trashed.uuid),
      set: [status: "trashed"]
    )

    Repo.update_all(from(f in Storage.File, where: f.uuid == ^managed.uuid),
      set: [system_managed: true]
    )

    Repo.update_all(from(f in Storage.File, where: f.uuid == ^failed.uuid),
      set: [status: "failed"]
    )

    Repo.update_all(from(f in Storage.File, where: f.uuid == ^processing.uuid),
      set: [status: "processing"]
    )

    run = start!(ctx) |> batch!()
    assert run.total == 3
    assert run.done == 2
    assert run.failed_count == 1

    assert [%{"problem" => "processing", "file_uuid" => uuid}] =
             Enum.find(History.for_run(run.uuid), &(&1.action == "job.batch")).metadata[
               "problems"
             ]

    assert uuid == processing.uuid
    assert Repo.get!(Storage.File, original.uuid)
  end

  test "the refreshed context preserves the browser's switched role", ctx do
    {:ok, _} = Settings.update_boolean_setting("role_switcher_enabled", true)
    on_exit(fn -> Settings.update_boolean_setting("role_switcher_enabled", false) end)
    {:ok, plain} = Roles.create_role(%{name: "No storage #{System.unique_integer([:positive])}"})
    {:ok, _} = Roles.assign_role(ctx.user, plain.name)
    scope = Scope.for_user(%{Repo.get!(Auth.User, ctx.user.uuid) | active_role_uuid: plain.uuid})
    refute Libraries.may_use_libraries?(scope)
    assert {:error, :not_allowed} = LibraryOperations.verify(scope, ctx.library.uuid, %{})
    assert LibraryOperations.list(scope).runs == []
  end

  test "operations and log pages are bounded and preserve all batch records", ctx do
    for _ <- 1..21 do
      {:ok, run, :started} = Jobs.System.start(Reconcile, {"library", ctx.library.uuid})
      assert {:ok, _} = LibraryOperations.control(Scope.for_user(ctx.user), run.uuid, "cancel")
    end

    {:ok, run, :started} = Jobs.System.start(Reconcile, {"library", ctx.library.uuid})

    for n <- 1..22 do
      current = Jobs.get_run(run.uuid)
      {:ok, _, token} = Engine.claim(current.uuid, current.generation)

      assert {:ok, _} =
               Engine.checkpoint(
                 run.uuid,
                 token,
                 {:more, %{done: 1, log: %{"checked" => 1, "batch" => n}}, []},
                 dispatch: false
               )
    end

    first = LibraryOperations.list(Scope.for_user(ctx.user))
    assert first.pages == 2
    assert length(first.runs) == 20
    assert hd(first.runs).uuid == run.uuid
    assert LibraryOperations.list(Scope.for_user(ctx.user), 100).page == 2
    logs = LibraryOperations.logs(Scope.for_user(ctx.user), run.uuid)
    assert logs.total == 23
    assert logs.pages == 2
    assert length(logs.entries) == 20
    assert length(LibraryOperations.logs(Scope.for_user(ctx.user), run.uuid, 2).entries) == 3
  end

  test "owner can verify without global job permissions; run, results and logs survive reload",
       ctx do
    file = upload!(ctx)
    refute Scope.can?(Scope.for_user(ctx.user), "jobs.manage")
    run = start!(ctx)
    assert run.args["mode"] == "presence"
    refute run.args["include_previews"]
    assert run.started_by_uuid == ctx.user.uuid
    updated = batch!(run)
    assert updated.state == "completed"
    assert updated.done == 1
    assert updated.failed_count == 0
    assert updated.result["checked"] == 1
    assert updated.result["needs_attention"] == 0

    assert [%{action: "job.started"}, %{action: "job.batch"}, %{action: "job.completed"}] =
             History.for_run(run.uuid)

    assert %{entries: entries} = LibraryOperations.logs(Scope.for_user(ctx.user), run.uuid)
    assert length(entries) == 3
    assert LibraryOperations.list(Scope.for_user(ctx.user)).total == 1
    assert LibraryOperations.list(Scope.for_user(ctx.other)).total == 0
    assert Repo.get!(Storage.File, file.uuid).status == "active"
  end

  test "one global verification slot covers different accounts and paused or draining checks",
       ctx do
    run = start!(ctx)
    other_scope = Scope.for_user(ctx.other)

    assert {:error, :verification_busy} =
             LibraryOperations.verify(other_scope, ctx.other_library.uuid, %{})

    assert {:ok, same, :existing} =
             LibraryOperations.verify(Scope.for_user(ctx.user), ctx.library.uuid, %{})

    assert same.uuid == run.uuid
    {:ok, paused} = LibraryOperations.control(Scope.for_user(ctx.user), run.uuid, "pause")
    assert paused.state == "paused"

    assert {:error, :verification_busy} =
             LibraryOperations.verify(other_scope, ctx.other_library.uuid, %{})

    {:ok, resumed} = LibraryOperations.control(Scope.for_user(ctx.user), run.uuid, "resume")
    {:ok, _, token} = Engine.claim(run.uuid, resumed.generation)
    {:ok, _} = LibraryOperations.control(Scope.for_user(ctx.user), run.uuid, "cancel")

    assert {:error, :verification_busy} =
             LibraryOperations.verify(other_scope, ctx.other_library.uuid, %{})

    {:ok, _} = Engine.checkpoint(run.uuid, token, {:done, %{}, %{}}, dispatch: false)
    assert {:ok, _, :started} = LibraryOperations.verify(other_scope, ctx.other_library.uuid, %{})
  end

  test "all verification modes share a rolling 30-day limit that survives pruning history", ctx do
    run = start!(ctx) |> batch!()
    scope = Scope.for_user(ctx.user)

    assert {:error, {:verification_cooldown, next}} =
             LibraryOperations.verify(scope, ctx.library.uuid, %{
               "mode" => "checksum",
               "include_previews" => "true"
             })

    assert DateTime.diff(next, run.inserted_at) == 30 * 86_400
    Repo.delete_all(from(r in PhoenixKit.Jobs.Run, where: r.uuid == ^run.uuid))

    assert {:error, {:verification_cooldown, _}} =
             LibraryOperations.verify(scope, ctx.library.uuid, %{})

    age_verification!(run)
    assert {:ok, _, :started} = LibraryOperations.verify(scope, ctx.library.uuid, %{})
  end

  test "a rejected start on a busy server does not consume the other library's allowance", ctx do
    run = start!(ctx)

    assert {:error, :verification_busy} =
             LibraryOperations.verify(Scope.for_user(ctx.other), ctx.other_library.uuid, %{})

    refute Libraries.get_library(ctx.other_library.uuid).settings["verification_last_started_at"]
    LibraryOperations.control(Scope.for_user(ctx.user), run.uuid, "cancel")

    assert {:ok, _, :started} =
             LibraryOperations.verify(Scope.for_user(ctx.other), ctx.other_library.uuid, %{})
  end

  test "invalid inserts roll back the cooldown reservation and create no dispatch", ctx do
    assert {:error, %Ecto.Changeset{}} =
             Engine.start(VerifyLibrary, {"library", ctx.library.uuid},
               args: %{"mode" => "presence", "include_previews" => false, "through" => nil},
               actor_uuid: "not-a-uuid"
             )

    refute Libraries.get_library(ctx.library.uuid).settings["verification_last_started_at"]
    assert LibraryOperations.list(Scope.for_user(ctx.user)).total == 0

    assert {:ok, _, :started} =
             LibraryOperations.verify(Scope.for_user(ctx.user), ctx.library.uuid, %{})
  end

  test "legacy job timestamps count and the rolling boundary becomes eligible exactly on time",
       ctx do
    run = start!(ctx) |> batch!()
    library = Libraries.get_library(ctx.library.uuid)

    Repo.update_all(from(l in Storage.Library, where: l.uuid == ^library.uuid),
      set: [settings: Map.delete(library.settings, "verification_last_started_at")]
    )

    fresh = Libraries.get_library(library.uuid)
    next = DateTime.add(run.inserted_at, 30 * 86_400, :second)

    assert VerificationPolicy.next_allowed_for([fresh], DateTime.add(next, -1, :second))[
             fresh.uuid
           ] == next

    assert VerificationPolicy.next_allowed_for([fresh], next)[fresh.uuid] == nil

    assert {:error, {:verification_cooldown, ^next}} =
             LibraryOperations.verify(Scope.for_user(ctx.user), library.uuid, %{})
  end

  test "trusted and admin start paths cannot bypass the admission policy", ctx do
    run = start!(ctx) |> batch!()
    args = run.args

    assert {:error, {:verification_cooldown, _}} =
             Jobs.System.start(VerifyLibrary, {"library", ctx.library.uuid}, args: args)

    assert {:error, {:verification_cooldown, _}} =
             Engine.start(VerifyLibrary, {"library", ctx.library.uuid}, args: args)
  end

  test "snapshot excludes later uploads; interrupted batches resume and never duplicate their logs",
       ctx do
    for n <- 1..6, do: upload!(ctx, "file-#{n}.txt")
    run = start!(ctx)
    upload!(ctx, "later.txt")
    first = batch!(run)
    assert first.state == "running"
    assert first.done == 5
    assert first.total == 6
    {:ok, paused} = LibraryOperations.control(Scope.for_user(ctx.user), run.uuid, "pause")
    assert paused.state == "paused"
    {:ok, resumed} = LibraryOperations.control(Scope.for_user(ctx.user), run.uuid, "resume")
    last = batch!(resumed)
    assert last.state == "completed"
    assert last.done == 6
    assert last.total == 6
    assert last.result["checked"] == 6

    assert {:error, :claim_lost} =
             Engine.checkpoint(run.uuid, "wrong-token", {:done, %{log: %{"checked" => 999}}, %{}})

    batches = Enum.filter(History.for_run(run.uuid), &(&1.action == "job.batch"))
    assert length(batches) == 2
    assert Enum.map(batches, & &1.metadata["checked"]) == [5, 1]
  end

  test "empty libraries and findings produce clear final results, with no automatic repair",
       ctx do
    empty = start!(ctx) |> batch!()
    assert empty.state == "completed"
    assert empty.result["checked"] == 0
    age_verification!(empty)
    file = upload!(ctx)
    original = Storage.get_file_instance_by_name(file.uuid, "original")
    File.rm!(Path.join(Local.root(ctx.bucket), original.file_name))
    run = start!(ctx) |> batch!()
    assert run.state == "completed"
    assert run.failed_count == 1
    assert run.done == 0

    assert [%{"problem" => "missing_or_inaccessible", "file_uuid" => uuid}] =
             Enum.find(History.for_run(run.uuid), &(&1.action == "job.batch")).metadata[
               "problems"
             ]

    assert uuid == file.uuid
    refute File.exists?(Path.join(Local.root(ctx.bucket), original.file_name))
    logs = LibraryOperations.logs(Scope.for_user(ctx.user), run.uuid)
    assert logs.names.files[file.uuid] == file.original_file_name
    assert logs.names.buckets[ctx.bucket.uuid] == ctx.bucket.name
    refute inspect(History.for_run(run.uuid)) =~ ctx.library.name
  end

  test "forged and revoked access cannot read logs, start checks or control runs", ctx do
    run = start!(ctx)
    other_scope = Scope.for_user(ctx.other)
    assert {:error, :not_allowed} = LibraryOperations.verify(other_scope, ctx.library.uuid, %{})
    assert LibraryOperations.get(other_scope, run.uuid) == nil
    assert LibraryOperations.logs(other_scope, run.uuid) == nil
    assert {:error, :not_allowed} = LibraryOperations.control(other_scope, run.uuid, "cancel")
    scope = Scope.for_user(ctx.user)

    assert {:error, :invalid_options} =
             LibraryOperations.verify(scope, ctx.library.uuid, %{"mode" => "repair"})

    :ok = Permissions.revoke_permission(ctx.role.uuid, "storage")
    assert LibraryOperations.list(scope).runs == []
    assert {:error, :not_allowed} = LibraryOperations.control(scope, run.uuid, "cancel")
    assert {:error, :not_allowed} = LibraryOperations.verify(scope, ctx.library.uuid, %{})
    assert LibraryOperations.logs(scope, run.uuid) == nil
  end

  test "members can read operations but cannot start or control them; removed members lose logs",
       ctx do
    {:ok, _} =
      Libraries.add_member(Scope.for_user(ctx.user), ctx.library, ctx.other.email, "viewer")

    run = start!(ctx)
    scope = Scope.for_user(ctx.other)
    assert LibraryOperations.get(scope, run.uuid)
    assert LibraryOperations.controls(scope, run) == []
    assert {:error, :not_allowed} = LibraryOperations.control(scope, run.uuid, "pause")
    assert {:error, :not_allowed} = LibraryOperations.verify(scope, ctx.library.uuid, %{})

    member =
      Repo.one!(
        from(m in Storage.LibraryMember,
          where: m.library_uuid == ^ctx.library.uuid and m.user_uuid == ^ctx.other.uuid
        )
      )

    Repo.delete!(member)
    assert LibraryOperations.logs(scope, run.uuid) == nil
  end

  test "cancel and retry keep history; other job kinds are never controllable", ctx do
    run = start!(ctx)
    scope = Scope.for_user(ctx.user)
    assert {:ok, %{state: "cancelled"}} = LibraryOperations.control(scope, run.uuid, "cancel")

    assert {:error, {:verification_cooldown, _}} =
             LibraryOperations.control(scope, run.uuid, "retry")

    refute "retry" in LibraryOperations.controls(scope, Jobs.get_run(run.uuid))
    age_verification!(run)
    assert {:ok, retry, :started} = LibraryOperations.control(scope, run.uuid, "retry")
    assert retry.uuid != run.uuid
    assert retry.args["retry_of"] == run.uuid
    assert {:ok, _, :existing} = LibraryOperations.verify(scope, ctx.library.uuid, %{})

    {:ok, unknown, :started} =
      Engine.start(PhoenixKit.Modules.Storage.Jobs.PurgeLibrary, {"library", ctx.library.uuid})

    assert LibraryOperations.get(scope, unknown.uuid) == nil
    assert {:error, :not_allowed} = LibraryOperations.control(scope, unknown.uuid, "cancel")
  end

  test "copy jobs save batch summaries and unfinished file IDs", ctx do
    file = upload!(ctx)
    {:ok, run, :started} = Jobs.System.start(Reconcile, {"library", ctx.library.uuid})
    assert {:ok, claimed, token} = Engine.claim(run.uuid, run.generation)
    outcome = RunWorker.batch_outcome(Reconcile, claimed, true)
    assert {:ok, _} = Engine.checkpoint(run.uuid, token, outcome, dispatch: false)
    assert Enum.any?(History.for_run(run.uuid), &(&1.action == "job.batch"))
    assert LibraryOperations.get(Scope.for_user(ctx.user), run.uuid)
    assert Repo.get!(Storage.File, file.uuid)
  end
end
