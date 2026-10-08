defmodule PhoenixKit.Modules.Storage.UploadInboxTest do
  @moduledoc """
  The waiting room between "the server has the bytes" and "they are stored":
  a failure, a crash or a refresh in between must leave the upload where the
  problems panel can find it, and nothing outside a user's own directory may
  ever be named.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Storage.UploadInbox

  @user "01900000-0000-7000-8000-00000000a11c"

  setup do
    root = Path.join(System.tmp_dir!(), "pk_inbox_test_#{System.unique_integer([:positive])}")
    previous = Application.get_env(:phoenix_kit, :upload_inbox_dir)
    Application.put_env(:phoenix_kit, :upload_inbox_dir, root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :upload_inbox_dir, previous),
        else: Application.delete_env(:phoenix_kit, :upload_inbox_dir)

      File.rm_rf(root)
    end)

    %{root: root}
  end

  defp src(content \\ "bytes") do
    path = Path.join(System.tmp_dir!(), "pk_inbox_src_#{System.unique_integer([:positive])}")
    File.write!(path, content)
    path
  end

  defp put!(content \\ "bytes") do
    {:ok, item, path} =
      UploadInbox.put(@user, src(content), %{
        client_name: "photo.jpg",
        client_type: "image/jpeg",
        client_size: byte_size(content)
      })

    {item, path}
  end

  # Ages an item past the point where nothing can still be working on it.
  defp age!(root, item, seconds) do
    meta = Path.join([root, @user, item.id <> ".json"])
    map = meta |> File.read!() |> Jason.decode!()
    File.write!(meta, Jason.encode!(%{map | "received_at" => map["received_at"] - seconds}))
  end

  test "put moves the bytes in, and locate finds the item from its path" do
    source = src("hello")
    {:ok, item, path} = UploadInbox.put(@user, source, %{client_name: "a.png"})

    refute File.exists?(source), "the source is moved, not copied — no stray temp file"
    assert File.read!(path) == "hello"
    assert UploadInbox.locate(path) == {@user, item.id}
    assert UploadInbox.path(@user, item.id) == {:ok, path}
  end

  test "a path outside the inbox is not an inbox item" do
    assert UploadInbox.locate(src()) == nil
    assert UploadInbox.locate(Path.join(UploadInbox.root(), "../../etc/passwd")) == nil
    assert UploadInbox.locate(nil) == nil
  end

  test "only uuids ever become directory or file names" do
    assert {:error, :invalid_user} = UploadInbox.put("../../tmp", src(), %{})
    assert UploadInbox.list("../..") == []
    assert UploadInbox.path(@user, "../../etc/passwd") == :error
    assert UploadInbox.delete(@user, "../x") == :ok
  end

  test "a fresh received item is not a problem — it may still be in a drain queue" do
    put!()
    assert UploadInbox.list(@user) == []
  end

  test "a failed item is listed with why, and its bytes stay for a retry" do
    {item, path} = put!()
    :ok = UploadInbox.fail(@user, item.id, "No storage is set up to receive files.")

    assert [%{id: id, status: "failed", error: "No storage" <> _}] = UploadInbox.list(@user)
    assert id == item.id
    assert File.exists?(path)
  end

  test "a received item nobody finished reads as interrupted once it is old enough", %{
    root: root
  } do
    {item, _path} = put!()
    age!(root, item, 600)

    assert [%{status: "interrupted"}] = UploadInbox.list(@user)

    # A retry makes it live again, so it is not listed while back in the queue.
    :ok = UploadInbox.touch(@user, item.id)
    assert UploadInbox.list(@user) == []
  end

  test "delete removes the bytes and the record", %{root: root} do
    {item, path} = put!()
    :ok = UploadInbox.delete(@user, item.id)

    refute File.exists?(path)
    refute File.exists?(Path.join([root, @user, item.id <> ".json"]))
  end

  test "items older than a week are swept on the next listing", %{root: root} do
    {item, path} = put!()
    UploadInbox.fail(@user, item.id, "x")
    age!(root, item, 8 * 24 * 3600)

    assert UploadInbox.list(@user) == []
    refute File.exists?(path)
  end

  test "a record whose bytes are gone is dropped — there is nothing to retry" do
    {item, path} = put!()
    UploadInbox.fail(@user, item.id, "x")
    File.rm!(path)

    assert UploadInbox.list(@user) == []
  end

  test "one user's inbox is never another's" do
    {item, _} = put!()
    UploadInbox.fail(@user, item.id, "x")

    assert UploadInbox.list("01900000-0000-7000-8000-00000000b0b0") == []
  end

  describe "who is working on an item" do
    @dest %{library_uuid: "01900000-0000-7000-8000-0000000000aa", folder_uuid: nil}

    defp alive_process do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end

    test "claiming records where the upload belongs, and a later claim keeps it" do
      {item, _} = put!()
      assert {:ok, %{dest: @dest}} = UploadInbox.claim(@user, item.id, @dest)

      other = %{library_uuid: nil, folder_uuid: "somewhere-else"}
      assert {:ok, %{dest: @dest}} = UploadInbox.claim(@user, item.id, other)
      assert %{dest: @dest} = UploadInbox.get(@user, item.id)
    end

    test "an item a live process holds is live, however old; one whose process is gone is interrupted at once",
         %{root: root} do
      {item, _} = put!()
      owner = alive_process()
      {:ok, _} = UploadInbox.claim(@user, item.id, @dest, owner)
      age!(root, item, 3600)

      assert UploadInbox.list(@user) == []
      assert UploadInbox.waiting?(@user)

      Process.exit(owner, :kill)
      Process.sleep(20)

      assert [%{status: "interrupted", dest: @dest}] = UploadInbox.list(@user)
      refute UploadInbox.waiting?(@user)
    end

    test "a second process cannot take, or discard, what a live one is storing" do
      {item, path} = put!()
      owner = alive_process()
      {:ok, _} = UploadInbox.claim(@user, item.id, @dest, owner)

      assert {:error, :busy} = UploadInbox.claim(@user, item.id, @dest, self())
      assert {:error, :busy} = UploadInbox.discard(@user, item.id, self())
      assert File.exists?(path), "the live process's bytes are untouched"

      # …and the owner may take it again (its own retry).
      assert {:ok, _} = UploadInbox.claim(@user, item.id, @dest, owner)
    end

    test "once its owner is gone, an item can be taken or discarded" do
      {item, path} = put!()
      owner = alive_process()
      {:ok, _} = UploadInbox.claim(@user, item.id, @dest, owner)
      Process.exit(owner, :kill)
      Process.sleep(20)

      assert {:ok, _} = UploadInbox.claim(@user, item.id, @dest, self())
      assert :ok = UploadInbox.discard(@user, item.id, self())
      refute File.exists?(path)
    end

    test "failing an item lets go of it" do
      {item, _} = put!()
      {:ok, _} = UploadInbox.claim(@user, item.id, @dest, alive_process())
      :ok = UploadInbox.fail(@user, item.id, "boom")

      assert %{owner: nil, status: "failed"} = UploadInbox.get(@user, item.id)
      assert [%{status: "failed"}] = UploadInbox.list(@user)
    end

    test "a copy is an item of its own, with the source left where it is" do
      source = src("shared")

      {:ok, copy, copy_path} =
        UploadInbox.put(@user, source, %{client_name: "c.png"}, copy: true)

      assert File.exists?(source)
      assert File.read!(copy_path) == "shared"
      assert UploadInbox.locate(copy_path) == {@user, copy.id}
    end
  end

  test "an inbox that cannot be made costs no bytes: the source is where it was" do
    source = src("keep me")
    File.mkdir_p!(UploadInbox.root())
    # A file where the user's directory should be: nothing can be written there.
    File.write!(Path.join(UploadInbox.root(), @user), "not a directory")

    assert {:error, _} = UploadInbox.put(@user, source, %{client_name: "a.png"})
    assert File.read!(source) == "keep me"
  end

  test "bytes with no record are swept after a week, and the inbox is private", %{root: root} do
    {item, path} = put!()
    File.rm!(Path.join([root, @user, item.id <> ".json"]))
    old = System.system_time(:second) - 8 * 24 * 3600
    File.touch!(path, old)
    :persistent_term.erase({UploadInbox, :last_sweep})

    # The next arrival sweeps every inbox.
    {_other, _} = put!("another")

    refute File.exists?(path)
    assert {:ok, %{mode: mode}} = File.stat(Path.join(root, @user))
    assert Bitwise.band(mode, 0o777) == 0o700
  end
end
