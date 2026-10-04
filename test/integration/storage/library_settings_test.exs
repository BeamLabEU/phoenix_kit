defmodule PhoenixKit.Modules.Storage.LibrarySettingsTest do
  @moduledoc """
  A library's own settings (its JSON `settings` column): the one place their keys
  are named, what is refused, and the first of them — annotated thumbnails, on or
  off for one library, otherwise the site setting.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage.{AnnotationThumbnail, Libraries}
  alias PhoenixKit.Settings

  @key "storage_annotated_thumbnails_enabled"

  setup do
    on_exit(fn -> PhoenixKit.Cache.invalidate(:settings, @key) end)
    :ok
  end

  defp library!(name \\ "Library #{System.unique_integer([:positive])}") do
    {:ok, library} = Libraries.create_system_library(%{name: name})
    library
  end

  defp site_default(value), do: {:ok, _} = Settings.update_boolean_setting(@key, value)

  describe "put_setting/3 and setting/2" do
    test "a library has no value of its own until one is set" do
      library = library!()

      assert Libraries.setting(library, :annotated_thumbnails) == nil
      assert Libraries.setting(library.uuid, :annotated_thumbnails) == nil
    end

    test "sets, changes and removes a value" do
      library = library!()

      assert {:ok, updated} = Libraries.put_setting(library, :annotated_thumbnails, true)
      assert Libraries.setting(updated, :annotated_thumbnails) == true
      assert Libraries.setting(library.uuid, :annotated_thumbnails) == true

      assert {:ok, _} = Libraries.put_setting(library, :annotated_thumbnails, false)
      assert Libraries.setting(library.uuid, :annotated_thumbnails) == false

      assert {:ok, _} = Libraries.put_setting(library, :annotated_thumbnails, nil)
      assert Libraries.setting(library.uuid, :annotated_thumbnails) == nil
    end

    test "refuses an unknown key and a value of the wrong type, and changes nothing" do
      library = library!()

      assert {:error, :unknown_setting} = Libraries.put_setting(library, :purging, true)
      assert {:error, :unknown_setting} = Libraries.put_setting(library, :nope, 1)

      assert {:error, :invalid_value} =
               Libraries.put_setting(library, :annotated_thumbnails, "yes")

      assert Libraries.get_library(library.uuid).settings == %{}
    end

    test "leaves the other keys of the map alone, the purge marker included" do
      library = library!()

      {1, _} =
        PhoenixKit.RepoHelper.repo().update_all(
          Ecto.Query.from(l in PhoenixKit.Modules.Storage.Library,
            where: l.uuid == ^library.uuid
          ),
          set: [settings: %{"purging" => true, "other" => 1}]
        )

      assert {:ok, updated} = Libraries.put_setting(library, :annotated_thumbnails, true)
      assert %{"purging" => true, "other" => 1, "annotated_thumbnails" => true} = updated.settings

      assert {:ok, updated} = Libraries.put_setting(library, :annotated_thumbnails, nil)
      assert updated.settings == %{"purging" => true, "other" => 1}
    end

    test "Media (nil) is a library like another" do
      assert Libraries.setting(nil, :annotated_thumbnails) ==
               Libraries.setting(Libraries.media_uuid(), :annotated_thumbnails)
    end

    test "setting_among/2 answers for many libraries in one go" do
      on = library!()
      off = library!()
      none = library!()
      {:ok, _} = Libraries.put_setting(on, :annotated_thumbnails, true)
      {:ok, _} = Libraries.put_setting(off, :annotated_thumbnails, false)

      own =
        Libraries.setting_among([on.uuid, off.uuid, none.uuid, on.uuid], :annotated_thumbnails)

      assert own == %{to_string(on.uuid) => true, to_string(off.uuid) => false}
    end
  end

  describe "annotated thumbnails for a library" do
    test "follow the site setting until the library chooses" do
      library = library!()

      site_default(false)
      refute AnnotationThumbnail.enabled_for?(library)
      refute AnnotationThumbnail.enabled_for?(library.uuid)

      site_default(true)
      assert AnnotationThumbnail.enabled_for?(library)
    end

    test "a library's own choice wins over the site setting, either way" do
      library = library!()

      site_default(false)
      {:ok, on} = Libraries.put_setting(library, :annotated_thumbnails, true)
      assert AnnotationThumbnail.enabled_for?(on)

      site_default(true)
      {:ok, off} = Libraries.put_setting(library, :annotated_thumbnails, false)
      refute AnnotationThumbnail.enabled_for?(off)
    end

    test "enabled_among/1 is the same rule for a page of files, Media included" do
      on = library!()
      off = library!()
      plain = library!()
      {:ok, _} = Libraries.put_setting(on, :annotated_thumbnails, true)
      {:ok, _} = Libraries.put_setting(off, :annotated_thumbnails, false)
      media = Libraries.media_uuid()

      site_default(false)

      enabled = AnnotationThumbnail.enabled_among([on.uuid, off.uuid, plain.uuid, nil])
      assert enabled == MapSet.new([to_string(on.uuid)])

      site_default(true)

      enabled = AnnotationThumbnail.enabled_among([on.uuid, off.uuid, plain.uuid, nil])
      assert enabled == MapSet.new([to_string(on.uuid), to_string(plain.uuid), media])
    end

    test "a file answers for its own library" do
      library = library!()
      {:ok, _} = Libraries.put_setting(library, :annotated_thumbnails, true)
      site_default(false)

      assert AnnotationThumbnail.enabled_for_file?(%{library_uuid: library.uuid})
      refute AnnotationThumbnail.enabled_for_file?(%{library_uuid: nil})
      refute AnnotationThumbnail.enabled_for_file_uuid?(Ecto.UUID.generate())
      refute AnnotationThumbnail.enabled_for_file_uuid?("not a uuid")
    end
  end
end
