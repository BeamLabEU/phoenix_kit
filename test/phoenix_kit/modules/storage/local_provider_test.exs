defmodule PhoenixKit.Modules.Storage.Providers.LocalTest do
  @moduledoc """
  The local provider writes an object whole or not at all: it copies next
  to the key and renames into place. Keys are content-addressed and written
  again by later jobs, and publishing a key trusts "it exists" to mean "it
  is complete".
  """
  # Not async: one test swaps the remembered start directory.
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Providers.Local

  @moduletag :tmp_dir

  defp bucket(dir), do: %{endpoint: Path.join(dir, "bucket")}

  test "a relative endpoint is relative to where the application started", %{tmp_dir: dir} do
    key = {Local, :cwd}
    started_in = :persistent_term.get(key, nil)
    :persistent_term.put(key, dir)

    try do
      # Not the working directory at call time: in development the code
      # reloader moves that into path dependencies while it recompiles.
      assert Local.root(%{endpoint: "priv/media"}) == Path.join(dir, "priv/media")
      assert Local.root(%{endpoint: nil}) == Path.join(dir, "priv/media")
      assert Local.root(%{endpoint: "/srv/media"}) == "/srv/media"

      source = Path.join(dir, "source.bin")
      File.write!(source, "bytes")
      assert {:ok, stored} = Local.store_file(%{endpoint: "relative"}, source, "k.bin")
      assert stored == Path.join([dir, "relative", "k.bin"])
    after
      if started_in,
        do: :persistent_term.put(key, started_in),
        else: :persistent_term.erase(key)
    end
  end

  test "a path's status names the directory files really go to", %{tmp_dir: dir} do
    key = {Local, :cwd}
    started_in = :persistent_term.get(key, nil)
    :persistent_term.put(key, dir)

    try do
      assert Local.resolve_path("priv/media") == Path.join(dir, "priv/media")
      assert Local.resolve_path("/srv/media") == "/srv/media"

      # Relative to the start directory, whatever the working directory is.
      assert {:missing, Path.join(dir, "priv/media")} ==
               Storage.local_path_status("priv/media")

      File.mkdir_p!(Path.join(dir, "priv/media"))

      assert {:ok, Path.join(dir, "priv/media")} ==
               Storage.local_path_status("priv/media")

      assert {:ok, "priv/media"} ==
               Storage.validate_and_normalize_path("priv/media")

      File.write!(Path.join(dir, "a-file"), "x")

      assert {:not_directory, Path.join(dir, "a-file")} ==
               Storage.local_path_status("a-file")

      assert {:error, :does_not_exist, Path.join(dir, "nope")} ==
               Storage.validate_and_normalize_path("nope")
    after
      if started_in,
        do: :persistent_term.put(key, started_in),
        else: :persistent_term.erase(key)
    end
  end

  test "the object appears complete, with nothing left beside it", %{tmp_dir: dir} do
    source = Path.join(dir, "source.bin")
    File.write!(source, :crypto.strong_rand_bytes(100_000))

    assert {:ok, stored} = Local.store_file(bucket(dir), source, "ab/cd/key.bin")

    assert File.read!(stored) == File.read!(source)
    assert File.ls!(Path.dirname(stored)) == ["key.bin"]
    assert Local.file_exists?(bucket(dir), "ab/cd/key.bin")
  end

  test "writing a key again replaces it", %{tmp_dir: dir} do
    first = Path.join(dir, "first.bin")
    second = Path.join(dir, "second.bin")
    File.write!(first, "first")
    File.write!(second, "second, longer")

    {:ok, stored} = Local.store_file(bucket(dir), first, "k.bin")
    {:ok, ^stored} = Local.store_file(bucket(dir), second, "k.bin")

    assert File.read!(stored) == "second, longer"
    assert File.ls!(Path.dirname(stored)) == ["k.bin"]
  end

  test "a failed write leaves no object and no partial file", %{tmp_dir: dir} do
    source = Path.join(dir, "source.bin")
    File.write!(source, "bytes")

    # The key's place is taken by a directory, so the final rename fails.
    blocked = Path.join([dir, "bucket", "taken"])
    File.mkdir_p!(Path.join(blocked, "inside"))

    assert {:error, _} = Local.store_file(bucket(dir), source, "taken")
    assert File.ls!(Path.join(dir, "bucket")) == ["taken"]
    assert File.dir?(blocked)
  end
end
