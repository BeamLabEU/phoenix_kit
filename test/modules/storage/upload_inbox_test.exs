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
end
