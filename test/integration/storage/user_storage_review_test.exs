defmodule PhoenixKit.Modules.Storage.UserStorageReviewTest do
  @moduledoc """
  Regression tests for the findings of `dev_docs/reviews/2026-09-30-user-owned-storage/CODEX_REVIEW.md`,
  each asserting the behavior the fix gives (the reviewer's own reproductions
  asserted the defect). In the order of the review:

    1. a crafted "test the bucket" event cannot reach the local provider
    2. a Tigris request is checked at the host it is really sent to; bucket
       names cannot carry URL delimiters
    3. the probe never overwrites or deletes an object it did not write
    4. a backup alone does not satisfy an upload
    5. a purge keeps every record of objects it could not delete
    6. trimming a backup snapshot keeps derived-only buckets
    7. the final storage choice is judged on the library as it is now
    8. the probe reads the object back
    9. an owned bucket is edited under the owned rules, and not from the
       site's screens
   10. the creation probe runs off the page's process
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Probe
  alias PhoenixKit.Jobs.Run
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Bucket, Endpoint, Libraries, Library, Manager, Profiles}
  alias PhoenixKit.Modules.Storage.Jobs.PurgeLibrary
  alias PhoenixKit.Modules.Storage.Providers.S3
  alias PhoenixKit.Modules.Storage.Workers.PurgeLibraryJob
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Components.LibrarySettings

  @stub __MODULE__.S3
  @moduletag capture_log: true

  # The bucket check runs in `Integrations.Probe`'s own process, which Req.Test's
  # per-process stubs do not reach.
  setup {Req.Test, :set_req_test_to_shared}

  setup do
    original_secret = Application.get_env(:phoenix_kit, :secret_key_base)
    original_req = Application.get_env(:ex_aws, :req_opts)
    Application.put_env(:phoenix_kit, :secret_key_base, "review-regression-secret")
    Application.put_env(:ex_aws, :req_opts, plug: {Req.Test, @stub})
    Repo.delete_all(PhoenixKit.Modules.Storage.ProfileBucket)
    Manager.invalidate_bucket_cache()
    root = Path.join(System.tmp_dir!(), "pk_review_reg_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      restore_env(:phoenix_kit, :secret_key_base, original_secret)
      restore_env(:ex_aws, :req_opts, original_req)
      Manager.invalidate_bucket_cache()
      File.rm_rf!(root)
    end)

    {:ok, store} = Agent.start_link(fn -> %{} end)
    memory_s3(store)
    %{root: root, store: store}
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp user!(permissions \\ []) do
    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{name: "Review reg #{n}"})
    for key <- permissions, do: Permissions.grant_permission(role.uuid, key)

    {:ok, user} =
      Auth.register_user(%{
        "email" => "review-reg-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.assign_role(user, role.name)
    Repo.get!(Auth.User, user.uuid)
  end

  defp connection!(owner) do
    {:ok, %{uuid: connection}} =
      Integrations.add_connection("object_storage", "review", nil, owner: {:user, owner})

    {:ok, _} =
      Integrations.save_setup(
        connection,
        %{"access_key" => "review-key", "secret_key" => "s"},
        nil,
        owner: {:user, owner}
      )

    connection
  end

  defp owned_bucket!(owner, extra \\ %{}) do
    {:ok, bucket} =
      Storage.create_owned_bucket(
        owner,
        Map.merge(
          %{
            "name" => "Review #{System.unique_integer([:positive])}",
            "provider" => "s3",
            "bucket_name" => "review-bucket",
            "integration_uuid" => connection!(owner),
            "endpoint" => "https://8.8.8.8"
          },
          extra
        )
      )

    bucket
  end

  defp site_bucket!(root, attrs \\ %{}) do
    {:ok, bucket} =
      Storage.create_bucket(
        Map.merge(
          %{
            name: "Site #{System.unique_integer([:positive])}",
            provider: "local",
            endpoint: root
          },
          attrs
        )
      )

    bucket
  end

  defp library!(user) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Library{
      name: "Library #{n}",
      slug: "review-#{n}",
      key_prefix: "review-#{n}",
      kind: "user",
      owner_uuid: user.uuid,
      visibility: "private"
    })
  end

  defp own_library!(user, mode, bucket_extra \\ %{}) do
    {:ok, profile} =
      Profiles.create_user_profile(user.uuid, owned_bucket!(user.uuid, bucket_extra), mode)

    {:ok, library} = Profiles.assign_user_profile(library!(user), profile)
    {library, profile}
  end

  defp upload!(user, library, root, content) do
    source = root <> ".#{System.unique_integer([:positive])}.txt"
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, content)
    checksum = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

    result =
      Storage.store_file_in_buckets(source, "document", user.uuid, checksum, "txt", "a.txt",
        library_uuid: library.uuid
      )

    File.rm(source)
    result
  end

  defp trash!(library) do
    {:ok, library} =
      library
      |> Ecto.Changeset.change(trashed_at: DateTime.truncate(DateTime.utc_now(), :second))
      |> Repo.update()

    library
  end

  # An in-memory S3. `opts`: `:deny` is a list of methods answered 403
  # (`"DELETE"`, `"GET"`, `"PUT"`).
  defp memory_s3(store, opts \\ []) do
    deny = Keyword.get(opts, :deny, [])

    Req.Test.stub(@stub, fn conn ->
      [_bucket | key_parts] = conn.path_info
      key = Enum.join(key_parts, "/")

      cond do
        conn.method in deny and key != "" ->
          Plug.Conn.send_resp(conn, 403, "Access denied")

        conn.method == "PUT" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          Agent.update(store, &Map.put(&1, key, body))
          conn |> Plug.Conn.put_resp_header("etag", ~s("etag")) |> Plug.Conn.send_resp(200, "")

        conn.method == "DELETE" ->
          Agent.update(store, &Map.delete(&1, key))
          Plug.Conn.send_resp(conn, 204, "")

        conn.method in ["GET", "HEAD"] and key == "" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/xml")
          |> Plug.Conn.send_resp(
            200,
            ~s(<ListBucketResult><Name>b</Name><IsTruncated>false</IsTruncated></ListBucketResult>)
          )

        true ->
          case Agent.get(store, &Map.get(&1, key)) do
            nil ->
              Plug.Conn.send_resp(conn, 404, "")

            body when conn.method == "HEAD" ->
              conn
              |> Plug.Conn.put_resp_header("content-length", to_string(byte_size(body)))
              |> Plug.Conn.send_resp(200, "")

            body ->
              Plug.Conn.send_resp(conn, 200, body)
          end
      end
    end)
  end

  # ── 1 ─────────────────────────────────────────────────────────────────────

  describe "1. the personal probe" do
    test "a crafted event cannot make the page test a local directory", %{conn: conn, root: root} do
      {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
      {:ok, _} = Settings.update_boolean_setting("storage_user_buckets_enabled", false)
      user = user!(~w(storage storage.create_library))
      File.mkdir_p!(root)
      sentinel = Path.join(root, ".phoenix_kit_test")
      File.write!(sentinel, "existing data")

      {:ok, view, html} = live(log_in_user(conn, user), Routes.path("/profile/settings/media"))
      refute html =~ "My own storage"
      target = with_target(view, "#profile-library-settings")

      render_change(target, "form_change", %{
        "library" => %{"storage" => %{"provider" => "local", "endpoint" => root}}
      })

      render_click(target, "test_storage", %{})
      render_async(view)

      assert File.read!(sentinel) == "existing data"
    end

    test "Storage.test_connection/1 refuses the local provider for an owned probe", %{root: root} do
      File.mkdir_p!(root)
      sentinel = Path.join(root, ".phoenix_kit_test")
      File.write!(sentinel, "existing data")

      assert {:error, message} =
               Storage.test_connection(%{
                 "provider" => "local",
                 "endpoint" => root,
                 "owner_uuid" => UUIDv7.generate()
               })

      assert message =~ "S3-compatible"
      assert File.read!(sentinel) == "existing data"
    end

    test "probe_own_storage/3 asks again who may, and validates the fields as a bucket" do
      {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
      {:ok, _} = Settings.update_boolean_setting("storage_user_buckets_enabled", true)
      plain = user!(~w(storage storage.create_library))
      scope = Scope.for_user(plain)

      assert {:error, :not_allowed} = Libraries.probe_own_storage(scope, %{"provider" => "s3"})

      allowed = user!(~w(storage storage.create_library storage.own_storage integrations))
      scope = Scope.for_user(allowed)

      assert {:error, %Ecto.Changeset{}} =
               Libraries.probe_own_storage(scope, %{"provider" => "local", "endpoint" => "/tmp"})

      connection = connection!(allowed.uuid)

      assert :ok =
               Libraries.probe_own_storage(
                 scope,
                 %{
                   "provider" => "s3",
                   "bucket_name" => "review-bucket",
                   "integration_uuid" => connection,
                   "endpoint" => "https://8.8.8.8"
                 }
               )
    end
  end

  # ── 2 ─────────────────────────────────────────────────────────────────────

  describe "2. the host a request is really sent to" do
    test "a virtual-host bucket is checked with its name in front" do
      bucket = %Bucket{provider: "tigris", bucket_name: "photos"}
      assert S3.request_host(bucket, "fly.storage.tigris.dev") == "photos.fly.storage.tigris.dev"

      assert S3.request_host(%Bucket{provider: "s3", bucket_name: "photos"}, "minio.example") ==
               "minio.example"
    end

    test "Tigris whose prefixed host resolves to loopback is refused before any request" do
      # A public base host and a bucket-prefixed one on loopback. Needs DNS; with
      # none, the name does not resolve and there is nothing to demonstrate.
      if Endpoint.check("https://a.127.0.0.1.sslip.io", :personal, resolve: true) ==
           {:error, :blocked_address} do
        bucket = %Bucket{
          name: "x",
          provider: "tigris",
          owner_uuid: UUIDv7.generate(),
          bucket_name: "a.127.0.0.1",
          endpoint: "https://sslip.io"
        }

        test_pid = self()

        Req.Test.stub(@stub, fn conn ->
          send(test_pid, {:request_host, conn.host})
          Plug.Conn.send_resp(conn, 200, "")
        end)

        assert_raise ArgumentError, ~r/local, private or metadata/, fn ->
          S3.file_exists?(bucket, "review.txt")
        end

        refute_received {:request_host, _}
      end
    end

    test "an owned bucket's name cannot carry URL delimiters", %{} do
      owner = UUIDv7.generate()

      for name <- [
            "127.0.0.1:443/x",
            "a/b",
            "a@b.c",
            "a b",
            "AB",
            "a..b",
            "192.168.0.1",
            "-ab",
            "ab-"
          ] do
        assert {:error, changeset} =
                 Storage.create_owned_bucket(owner, %{
                   "name" => "x",
                   "provider" => "s3",
                   "bucket_name" => name,
                   "integration_uuid" => connection!(owner)
                 })

        assert %{bucket_name: [_]} =
                 Ecto.Changeset.traverse_errors(changeset, fn {m, _} -> m end),
               name
      end
    end

    test "and a stored one that slipped through is refused when a request is built" do
      bucket = %Bucket{
        name: "x",
        provider: "tigris",
        owner_uuid: UUIDv7.generate(),
        bucket_name: "127.0.0.1:443/x",
        endpoint: "https://8.8.8.8"
      }

      assert_raise ArgumentError, ~r/bucket name is not valid/, fn -> S3.aws_config(bucket) end
      assert {:error, _} = S3.signed_download_url(bucket, "review.txt", [])
    end

    test "ordinary bucket names are fine" do
      for name <- ["my-photos", "a.b.c", "photos-2026", "abc"],
          do: assert(S3.valid_bucket_name?(name), name)
    end
  end

  # ── 3 and 8 ───────────────────────────────────────────────────────────────

  describe "3. and 8. the probe" do
    test "never touches an object it did not write", %{store: store} do
      bucket = owned_bucket!(UUIDv7.generate())

      for key <- [".phoenix_kit/connection-test", "important.txt", ".phoenix_kit/other"],
          do: Agent.update(store, &Map.put(&1, key, "existing #{key}"))

      before = Agent.get(store, & &1)

      assert :ok = S3.test_connection(bucket)
      assert :ok = S3.test_connection(bucket)

      assert Agent.get(store, & &1) == before
    end

    test "uses a fresh key each time" do
      bucket = owned_bucket!(UUIDv7.generate())
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        if conn.method == "PUT", do: send(test_pid, {:put, Enum.join(tl(conn.path_info), "/")})

        if conn.method == "GET",
          do: Plug.Conn.send_resp(conn, 200, "ok"),
          else: Plug.Conn.send_resp(conn, 200, "")
      end)

      S3.test_connection(bucket)
      S3.test_connection(bucket)

      assert_received {:put, first}
      assert_received {:put, second}
      assert first != second
      assert first =~ ~r/\A\.phoenix_kit\/connection-test-[0-9a-f]{24}\z/
    end

    test "reads the object back: a key that cannot read is not called readable", %{store: store} do
      bucket = owned_bucket!(UUIDv7.generate())
      memory_s3(store, deny: ["GET", "HEAD"])

      assert {:error, message} = S3.test_connection(bucket)
      assert message =~ "read"
      # What it wrote is removed again even though a stage failed.
      assert Agent.get(store, & &1) == %{}
    end

    test "a key that cannot write says so, and needs no listing", %{store: store} do
      bucket = owned_bucket!(UUIDv7.generate())
      memory_s3(store, deny: ["PUT"])

      assert {:error, message} = S3.test_connection(bucket)
      assert message =~ "written to"
    end

    test "a key that cannot delete names the file it left", %{store: store} do
      bucket = owned_bucket!(UUIDv7.generate())
      memory_s3(store, deny: ["DELETE"])

      assert {:error, message} = S3.test_connection(bucket)
      assert message =~ "delete"
      assert message =~ ".phoenix_kit/connection-test-"
    end
  end

  # ── 4 and 6 ───────────────────────────────────────────────────────────────

  describe "4. a backup does not satisfy an upload by itself" do
    test "a read-only site is not something to back up", %{root: root} do
      user = user!()
      site = site_bucket!(root)

      {:ok, _} =
        Profiles.put_bucket(Profiles.default_profile(), site.uuid, %{status: "read_only"})

      assert {:error, :no_site_storage} =
               Profiles.create_user_profile(user.uuid, owned_bucket!(user.uuid), :backup)
    end

    test "a failed site write is not made up for by the backup", %{root: root, store: store} do
      user = user!()
      # A "directory" that is a file: nothing can be written beneath it.
      blocked = root <> ".blocked"
      File.write!(blocked, "x")
      on_exit(fn -> File.rm(blocked) end)
      site = site_bucket!(Path.join(blocked, "bucket"))
      {:ok, _} = Profiles.put_bucket(Profiles.default_profile(), site.uuid, %{})

      {library, _profile} = own_library!(user, :backup)

      assert {:error, _} = upload!(user, library, root, "backup only")
      # What the backup had been given is undone with the failed upload.
      assert Agent.get(store, & &1) == %{}
    end

    test "with a working site bucket the upload is on both", %{root: root, store: store} do
      user = user!()
      site = site_bucket!(root)
      {:ok, _} = Profiles.put_bucket(Profiles.default_profile(), site.uuid, %{})
      {library, _profile} = own_library!(user, :backup)

      assert {:ok, file} = upload!(user, library, root, "both")
      assert [{key, "both"}] = Agent.get(store, &Enum.to_list/1)
      assert File.exists?(Path.join(root, key))
      assert {:local, _path} = Manager.get_file_access(key, file_uuid: file.uuid)
    end
  end

  describe "6. trimming the snapshot" do
    test "four site buckets and the backup: each one a candidate, counted per kind", %{
      root: root
    } do
      user = user!()
      default = Profiles.default_profile()

      for n <- 1..4 do
        site = site_bucket!(Path.join(root, to_string(n)))
        {:ok, _} = Profiles.put_bucket(default, site.uuid, %{serve_order: n})
      end

      {:ok, profile} = Profiles.create_user_profile(user.uuid, owned_bucket!(user.uuid), :backup)

      # The site's buckets are local, the user's is the cloud copy.
      assert length(Manager.placement_candidates(profile)) == 5
      assert {profile.copies_local, profile.copies_cloud} == {4, 1}
      assert profile.copies_originals == 5
    end

    test "more than four original buckets keep the first four, active before read-only", %{
      root: root
    } do
      user = user!()
      default = Profiles.default_profile()

      for n <- 1..6 do
        site = site_bucket!(Path.join(root, to_string(n)))

        {:ok, _} =
          Profiles.put_bucket(default, site.uuid, %{
            serve_order: n,
            status: if(n == 1, do: "read_only", else: "active")
          })
      end

      {:ok, profile} = Profiles.create_user_profile(user.uuid, owned_bucket!(user.uuid), :backup)

      site_rows = Enum.reject(profile.buckets, &(&1.role == "backup"))
      assert length(site_rows) == 4
      # The read-only one was the first by serve order, yet an active one is kept instead.
      assert Enum.all?(site_rows, &(&1.status == "active"))
      assert profile.copies_originals == 5
    end
  end

  # ── 7 ─────────────────────────────────────────────────────────────────────

  describe "7. the final storage choice" do
    test "a stale struct cannot move a library that is on user storage now" do
      user = user!()
      stale = library!(user)
      {:ok, profile} = Profiles.create_user_profile(user.uuid, owned_bucket!(user.uuid), :only)
      {:ok, _} = Profiles.assign_user_profile(stale, profile)
      {:ok, site} = Profiles.create_profile(%{name: "Site #{System.unique_integer([:positive])}"})

      assert {:error, :user_storage_locked} = Profiles.set_library_profile(stale, site.uuid)

      assert to_string(Libraries.get_library(stale.uuid).storage_profile_uuid) ==
               to_string(profile.uuid)
    end

    test "a library that already has its own storage cannot be given another" do
      user = user!()
      {:ok, first} = Profiles.create_user_profile(user.uuid, owned_bucket!(user.uuid), :only)
      {:ok, second} = Profiles.create_user_profile(user.uuid, owned_bucket!(user.uuid), :only)
      {:ok, library} = Profiles.assign_user_profile(library!(user), first)

      assert {:error, :user_storage_locked} = Profiles.assign_user_profile(library, second)
      # Not even with a struct that still looks new.
      assert {:error, :user_storage_locked} =
               Profiles.assign_user_profile(%{library | storage_profile_uuid: nil}, second)

      assert to_string(Libraries.get_library(library.uuid).storage_profile_uuid) ==
               to_string(first.uuid)
    end

    test "a library on a site profile cannot be given a user's storage after the fact" do
      user = user!()
      {:ok, site} = Profiles.create_profile(%{name: "Site #{System.unique_integer([:positive])}"})
      library = library!(user)
      {:ok, library} = Profiles.set_library_profile(library, site.uuid)
      {:ok, own} = Profiles.create_user_profile(user.uuid, owned_bucket!(user.uuid), :only)

      assert {:error, :user_storage_locked} = Profiles.assign_user_profile(library, own)
    end
  end

  # ── 5 ─────────────────────────────────────────────────────────────────────

  describe "5. purging keeps what it could not clean up" do
    test "a refused delete leaves the file, library, profile and bucket, and is retried", %{
      root: root,
      store: store
    } do
      user = user!()
      {library, profile} = own_library!(user, :only)
      [bucket] = Storage.list_owned_buckets(user.uuid)
      assert {:ok, file} = upload!(user, library, root, "private bytes")
      [{key, _}] = Agent.get(store, &Enum.to_list/1)

      memory_s3(store, deny: ["DELETE"])
      library = trash!(library)

      assert {:error, :objects_remain} = Libraries.purge_library(library)

      # Everything that says where the bytes are, and how to reach them, is still there.
      assert Agent.get(store, &Map.has_key?(&1, key))
      assert Repo.get(Storage.File, file.uuid)
      assert Libraries.get_library(library.uuid)
      assert Profiles.get_profile(profile.uuid)
      assert Storage.get_bucket(bucket.uuid)

      # The key is allowed to delete again: the retry finishes the job.
      memory_s3(store)
      assert :ok = Libraries.purge_library(library.uuid)

      assert Agent.get(store, & &1) == %{}
      assert Repo.get(Storage.File, file.uuid) == nil
      assert Libraries.get_library(library.uuid) == nil
      assert Profiles.get_profile(profile.uuid) == nil
      assert Storage.get_bucket(bucket.uuid) == nil
    end

    test "the purge run is retried, not dropped, while objects remain", %{
      root: root,
      store: store
    } do
      start_supervised!(
        {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
      )

      user = user!()
      {library, _profile} = own_library!(user, :only)
      {:ok, _file} = upload!(user, library, root, "private bytes")
      memory_s3(store, deny: ["DELETE"])
      library = trash!(library)

      # The Oban job every place queues starts the run ...
      assert :ok =
               PurgeLibraryJob.perform(%Oban.Job{
                 args: %{"library_uuid" => library.uuid}
               })

      assert %Run{kind: "storage.purge_library", state: "queued", title: title} =
               run = Repo.one!(from r in Run, where: r.kind == "storage.purge_library")

      # a user's library is private: its name is not in the title
      assert title == "Delete a user's library and its files"
      refute title =~ library.name

      # ... which tries again each time the objects remain, and then fails
      # visibly (the daily prune starts it again) — it is never silently dropped.
      Oban.drain_queue(queue: :file_processing, with_scheduled: true, with_recursion: true)

      assert %Run{state: "failed", error: error, interruptions: 4} = Repo.get!(Run, run.uuid)
      assert error =~ "objects remain"
      assert Libraries.get_library(library.uuid)

      # Not controllable while it works: it has no pause or cancel to offer.
      assert PurgeLibrary.controls() == []
    end

    test "the purge run finishes the job once the objects can be deleted", %{
      root: root,
      store: store
    } do
      start_supervised!(
        {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
      )

      user = user!()
      {library, _profile} = own_library!(user, :only)
      {:ok, _file} = upload!(user, library, root, "private bytes")
      memory_s3(store)
      library = trash!(library)

      assert :ok = PurgeLibraryJob.perform(%Oban.Job{args: %{"library_uuid" => library.uuid}})
      Oban.drain_queue(queue: :file_processing, with_scheduled: true, with_recursion: true)

      assert %Run{state: "completed", result: %{"purged" => true}} =
               Repo.one!(from r in Run, where: r.kind == "storage.purge_library")

      assert Libraries.get_library(library.uuid) == nil
    end

    test "a library that is gone ends its run with nothing to do" do
      start_supervised!(
        {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
      )

      assert :ok =
               PurgeLibraryJob.perform(%Oban.Job{args: %{"library_uuid" => Ecto.UUID.generate()}})

      Oban.drain_queue(queue: :file_processing, with_scheduled: true, with_recursion: true)

      assert %Run{state: "completed", result: %{"skipped" => "the library is gone"}} =
               Repo.one!(from r in Run, where: r.kind == "storage.purge_library")
    end

    test "with the credentials gone nothing can wait for the bucket: the purge goes on", %{
      root: root,
      store: store
    } do
      user = user!()
      {library, profile} = own_library!(user, :only)
      [bucket] = Storage.list_owned_buckets(user.uuid)
      {:ok, _file} = upload!(user, library, root, "left behind")

      # What deleting the account does first.
      Integrations.remove_connection(bucket.integration_uuid, nil, owner: {:user, user.uuid})
      library = trash!(library)

      assert :ok = Libraries.purge_library(library)

      # The object is still in their bucket: unreachable, and said so in the log.
      assert map_size(Agent.get(store, & &1)) == 1
      assert Libraries.get_library(library.uuid) == nil
      assert Profiles.get_profile(profile.uuid) == nil
    end

    test "a library on the site's storage is purged as before", %{root: root} do
      user = user!()
      site = site_bucket!(root)
      {:ok, _} = Profiles.put_bucket(Profiles.default_profile(), site.uuid, %{})
      library = library!(user)
      assert {:ok, file} = upload!(user, library, root, "site file")

      assert :ok = Libraries.purge_library(trash!(library))
      assert Repo.get(Storage.File, file.uuid) == nil
    end
  end

  # ── 9 ─────────────────────────────────────────────────────────────────────

  describe "9. editing an owned bucket" do
    test "cannot point at a connection its owner does not own" do
      owner = UUIDv7.generate()
      owned = owned_bucket!(owner)
      other = connection!(UUIDv7.generate())

      assert {:error, changeset} = Storage.update_bucket(owned, %{integration_uuid: other})

      assert %{integration_uuid: ["is not one of your connections"]} =
               Ecto.Changeset.traverse_errors(changeset, fn {m, _} -> m end)

      {:ok, %{uuid: system}} = Integrations.add_connection("object_storage", "system")
      {:ok, _} = Integrations.save_setup(system, %{"access_key" => "k", "secret_key" => "s"})
      assert {:error, _} = Storage.update_bucket(owned, %{integration_uuid: system})

      assert to_string(Storage.get_bucket(owned.uuid).integration_uuid) ==
               to_string(owned.integration_uuid)
    end

    test "is held to the personal endpoint policy" do
      owner = UUIDv7.generate()
      owned = owned_bucket!(owner)

      assert {:error, changeset} = Storage.update_bucket(owned, %{endpoint: "https://10.0.0.5"})
      assert %{endpoint: [_]} = Ecto.Changeset.traverse_errors(changeset, fn {m, _} -> m end)
    end

    test "a valid edit of an owned bucket works" do
      owner = UUIDv7.generate()
      owned = owned_bucket!(owner)

      assert {:ok, updated} = Storage.update_bucket(owned, %{region: "eu-west-1", enabled: false})
      assert updated.region == "eu-west-1"
      refute updated.enabled
      assert updated.access_type == "signed"
    end

    test "the site's bucket screens do not find it", %{conn: conn} do
      owned = owned_bucket!(UUIDv7.generate())
      assert Storage.get_site_bucket(owned.uuid) == nil
      assert Storage.get_site_bucket("not-a-uuid") == nil

      {admin, _} = create_admin_user()
      conn = log_in_user(conn, admin)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, Routes.path("/admin/settings/media/buckets/#{owned.uuid}/edit"))

      assert to == Routes.path("/admin/settings/media")

      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/media"))
      render_click(view, "toggle_bucket", %{"id" => owned.uuid})
      render_click(view, "delete_bucket", %{"id" => owned.uuid})

      assert %Bucket{enabled: true} = Storage.get_bucket(owned.uuid)
    end
  end

  # ── 10 ────────────────────────────────────────────────────────────────────

  describe "10. the creation probe" do
    setup do
      {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
      {:ok, _} = Settings.update_boolean_setting("storage_user_buckets_enabled", true)
      user = user!(~w(storage storage.create_library storage.own_storage integrations))
      %{user: user}
    end

    defp mounted(user) do
      {:ok, socket} =
        LibrarySettings.update(
          %{id: "profile-library-settings", scope: Scope.for_user(user)},
          %Phoenix.LiveView.Socket{}
        )

      socket
    end

    test "a probe that passes, off the page's process, creates the library", %{user: user} do
      connection = connection!(user.uuid)

      attrs = %{
        "name" => "Photos",
        "storage" => %{
          "mode" => "only",
          "integration_uuid" => connection,
          "provider" => "s3",
          "bucket_name" => "my-photos",
          "endpoint" => "https://8.8.8.8"
        }
      }

      socket = mounted(user)
      socket = Phoenix.Component.assign(socket, creating: true, pending_create: attrs)

      {:noreply, socket} = LibrarySettings.handle_async(:probe_storage, {:ok, :ok}, socket)

      assert {:success, _} = socket.assigns.message
      assert socket.assigns.creating == false
      assert [%{library: %{name: "Photos"}}] = socket.assigns.owned
      # The library was created without checking the bucket a second time.
      assert [_bucket] = Storage.list_owned_buckets(user.uuid)
    end

    test "a probe that fails, or dies, creates nothing and ends the wait", %{user: user} do
      socket =
        Phoenix.Component.assign(mounted(user), creating: true, pending_create: %{"name" => "x"})

      {:noreply, failed} =
        LibrarySettings.handle_async(
          :probe_storage,
          {:ok, {:error, "no write permission"}},
          socket
        )

      assert {:error, message} = failed.assigns.message
      assert message =~ "no write permission"
      assert failed.assigns.creating == false
      assert failed.assigns.owned == []

      {:noreply, died} = LibrarySettings.handle_async(:probe_storage, {:exit, :killed}, socket)
      assert {:error, _} = died.assigns.message
      assert died.assigns.creating == false
      assert Storage.list_owned_buckets(user.uuid) == []
    end

    test "the probe itself has a deadline", %{} do
      # `Storage.test_connection/1` runs a remote bucket's check in `Integrations.Probe`
      # (15 s), isolated from its caller: an overrun is an error, not a hang.
      assert is_function(&Probe.run/2)

      assert {:error, _} =
               Probe.run(fn -> Process.sleep(200) end, 20)
    end
  end
end
