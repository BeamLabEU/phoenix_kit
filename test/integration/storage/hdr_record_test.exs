defmodule PhoenixKit.Modules.Storage.HdrRecordTest do
  @moduledoc """
  Reading a photo's EXIF also records whether its original carries an HDR gain map
  (`metadata["hdr"]`): what a photo uploaded before the check existed needs.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Users.Auth

  @moduletag :tmp_dir
  @buckets_cache :phoenix_kit_buckets_cache

  setup %{tmp_dir: tmp} do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    Repo.update_all(Bucket, set: [enabled: false])
    on_exit(fn -> :persistent_term.erase(@buckets_cache) end)

    {:ok, _} =
      Storage.create_bucket(%{
        name: "hdr-#{n}",
        provider: "local",
        endpoint: Path.join(tmp, "bucket"),
        enabled: true,
        priority: 0
      })

    {:ok, user} =
      Auth.register_user(%{"email" => "hdr-#{n}@example.com", "password" => "ValidPassword123!"})

    %{tmp: tmp, user: user, n: n}
  end

  defp store!(ctx, name, bytes) do
    path = Path.join(ctx.tmp, name)
    File.write!(path, bytes)
    sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

    case Storage.store_file_in_buckets(path, "image", ctx.user.uuid, sha, "jpg", name) do
      {:ok, file} -> file
      {:ok, file, _} -> file
    end
  end

  # SOI, an ISO 21496-1 marker, a Multi-Picture directory naming a second picture
  # that follows the first.
  defp gain_map_jpeg do
    iso = <<0xFF, 0xE2, 2 + 28::16, "urn:iso:std:iso:ts:21496:-1\0">>
    head = <<0xFF, 0xD8>> <> iso

    mp = fn offset ->
      entries = <<0::32, 100::32, 0::32, 0::32, 0::32, 120::32, offset::32, 0::32>>

      ifd =
        <<2::16, 0xB001::16, 4::16, 1::32, 2::32, 0xB002::16, 7::16, 32::32, 38::32, 0::32>>

      payload = "MPF\0MM" <> <<0x2A::16, 8::32>> <> ifd <> entries
      <<0xFF, 0xE2, byte_size(payload) + 2::16>> <> payload
    end

    primary_tail = <<0xFF, 0xDA, 0, 2>> <> :binary.copy(<<0>>, 20)
    second_at = byte_size(head) + byte_size(mp.(0)) + byte_size(primary_tail)
    seg = mp.(second_at - (byte_size(head) + 8))

    head <> seg <> primary_tail <> <<0xFF, 0xD8>> <> :binary.copy(<<0>>, 118)
  end

  test "read_exif records the gain map of a photo that has one, and an empty one otherwise",
       ctx do
    with_map = store!(ctx, "map.jpg", gain_map_jpeg())
    plain = store!(ctx, "plain.jpg", <<0xFF, 0xD8, 0xFF, 0xD9>> <> "plain #{ctx.n}")

    assert {:ok, row} = Storage.read_exif(with_map)
    assert %{"gain_map" => true, "kinds" => ["iso21496"]} = row.metadata["hdr"]

    assert {:ok, row} = Storage.read_exif(plain)
    assert row.metadata["hdr"] == %{}
  end
end
