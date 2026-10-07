defmodule PhoenixKitWeb.Live.Users.MediaUploadProblemsTest do
  @moduledoc """
  Reported from the field: a client uploaded about ten pictures, six
  arrived, and nothing said which four were missing or offered a way to try
  again. Every way an upload can fail to land is now a named row in the
  media browser's "Upload problems" panel:

    * turned away before transfer — more than fit at once, too large — with
      the entry cleared so it stops holding a slot;
    * received but not stored — kept in the user's UploadInbox with why,
      retryable, and still listed after a reload;
    * received but never finished (the LiveView died, the page reloaded) —
      listed as interrupted, retryable;
    * a store that raises — one failed upload, not a dead LiveView.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.UploadInbox
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @buckets_cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_upload_problems_#{n}")
    inbox = Path.join(System.tmp_dir!(), "pk_upload_problems_inbox_#{n}")
    previous_inbox = Application.get_env(:phoenix_kit, :upload_inbox_dir)
    Application.put_env(:phoenix_kit, :upload_inbox_dir, inbox)

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "upload-problems-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)

      if previous_inbox,
        do: Application.put_env(:phoenix_kit, :upload_inbox_dir, previous_inbox),
        else: Application.delete_env(:phoenix_kit, :upload_inbox_dir)

      File.rm_rf(root)
      File.rm_rf(inbox)
    end)

    {user, _token} = create_admin_user()
    %{user: user}
  end

  defp open(conn, user) do
    {:ok, view, _html} = live(log_in_user(conn, user), Routes.path("/admin/media"))
    view
  end

  defp files(names),
    do:
      Enum.map(
        names,
        &%{name: &1, content: "#{&1}-#{System.unique_integer()}", type: "image/png"}
      )

  defp drop(view, files) do
    file_input(view, "#folder-drop-upload-form", :media_files, files)
  end

  # The browser stores, then waits out its batch window before settling.
  defp settle(view) do
    Process.sleep(800)
    render(view)
  end

  defp stored_count(user) do
    Repo.aggregate(from(f in Storage.File, where: f.user_uuid == ^user.uuid), :count)
  end

  defp entries(view), do: :sys.get_state(view.pid).socket.assigns.uploads.media_files.entries

  # A bucket in use cannot be disabled through the API (rightly), so the test
  # switches every bucket off underneath it — inside the sandbox transaction,
  # rolled back with the test. The store then answers :no_buckets_configured,
  # a real failure through the real path.
  defp storage_off do
    Repo.update_all(Storage.Bucket, set: [enabled: false])
    :persistent_term.erase(@buckets_cache)
  end

  defp storage_on do
    Repo.update_all(Storage.Bucket, set: [enabled: true])
    :persistent_term.erase(@buckets_cache)
  end

  describe "turned away before transfer" do
    test "eleven at once: ten upload, the eleventh is named — and stops holding a slot", %{
      conn: conn,
      user: user
    } do
      view = open(conn, user)
      dropped = files(for i <- 1..11, do: "pic#{i}.png")
      input = drop(view, dropped)

      for i <- 1..10, do: render_upload(input, "pic#{i}.png")
      html = settle(view)

      assert stored_count(user) == 10
      assert html =~ "1 file did not upload"
      assert html =~ "pic11.png"
      assert html =~ "Up to 10 files upload at once"

      assert entries(view) == [],
             "a rejected entry left in the list sits at 0% forever and costs the next drop a slot"
    end

    test "a file over the size limit is named with the limit", %{conn: conn, user: user} do
      {:ok, _} = Settings.update_setting("storage_max_upload_size_mb", "1")

      view = open(conn, user)

      input =
        drop(view, [%{name: "huge.png", content: :binary.copy("x", 1_500_000), type: "image/png"}])

      render_upload(input, "huge.png", 0)
      html = render(view)

      assert html =~ "huge.png"
      assert html =~ "Larger than the 1 MB upload limit."
      assert entries(view) == []
      assert stored_count(user) == 0
    end
  end

  describe "received, but not stored" do
    test "the file is kept, listed with why, still listed after a reload, and Retry stores it",
         %{conn: conn, user: user} do
      view = open(conn, user)
      storage_off()

      input = drop(view, files(["receipt.png"]))
      render_upload(input, "receipt.png")
      html = settle(view)

      assert html =~ "1 file did not upload"
      assert html =~ "receipt.png"
      assert html =~ "No storage is set up to receive files."
      assert [%{status: "failed"}] = UploadInbox.list(user.uuid)

      # A reload is a new LiveView: the problem lives on disk, not in a socket.
      view = open(build_conn(), user)
      assert render(view) =~ "receipt.png"

      storage_on()
      view |> element("button[phx-click=retry_upload]") |> render_click()
      html = settle(view)

      assert stored_count(user) == 1
      refute html =~ "did not upload"
      assert UploadInbox.list(user.uuid) == []
    end

    test "Discard lets go of the kept bytes", %{conn: conn, user: user} do
      view = open(conn, user)
      storage_off()
      render_upload(drop(view, files(["gone.png"])), "gone.png")
      settle(view)

      view |> element("button[phx-click=discard_upload]") |> render_click()

      refute render(view) =~ "gone.png"
      assert UploadInbox.list(user.uuid) == []
    end
  end

  describe "received, but never finished" do
    test "an inbox item nobody finished reads as interrupted and Retry stores it", %{
      conn: conn,
      user: user
    } do
      src = Path.join(System.tmp_dir!(), "pk_interrupted_#{System.unique_integer([:positive])}")
      File.write!(src, "interrupted-#{System.unique_integer()}")

      {:ok, item, _path} =
        UploadInbox.put(user.uuid, src, %{
          client_name: "halfway.png",
          client_type: "image/png",
          client_size: 20
        })

      meta = Path.join([UploadInbox.root(), user.uuid, item.id <> ".json"])
      map = meta |> File.read!() |> Jason.decode!()
      File.write!(meta, Jason.encode!(%{map | "received_at" => map["received_at"] - 600}))

      view = open(conn, user)
      html = render(view)
      assert html =~ "halfway.png"
      assert html =~ "Saving was interrupted"

      view |> element("button[phx-click=retry_upload]") |> render_click()
      settle(view)

      assert stored_count(user) == 1
      assert UploadInbox.list(user.uuid) == []
    end
  end

  test "a store that raises is one failed upload, not a dead LiveView", %{
    conn: conn,
    user: user
  } do
    src = Path.join(System.tmp_dir!(), "pk_raises_#{System.unique_integer([:positive])}")
    File.write!(src, "x")

    {:ok, item, path} =
      UploadInbox.put(user.uuid, src, %{client_name: "cursed.png", client_size: 1})

    UploadInbox.fail(user.uuid, item.id, "first try failed")

    # Bytes that cannot be read: the hash in the store raises on a directory.
    File.rm!(path)
    File.mkdir_p!(path)

    view = open(conn, user)
    view |> element("button[phx-click=retry_upload]") |> render_click()
    html = settle(view)

    assert Process.alive?(view.pid)
    assert html =~ "cursed.png"
    assert html =~ "The server ran into an error while saving it."
  end
end
