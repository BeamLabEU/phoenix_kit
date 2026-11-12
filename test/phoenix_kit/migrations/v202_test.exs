defmodule PhoenixKit.Migrations.Postgres.V202Test do
  @moduledoc """
  V202's storage libraries, run as the real SQL against rows that already
  exist: down removes the partition, up puts every existing file, folder and
  link into Media without being told, a writer that names no library lands
  there too, and the new keys hold.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.{V202, V203, V232}
  alias PhoenixKit.Test.Repo

  @media V202.media_uuid()

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)

  defp query(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp marker do
    [[marker]] = query("SELECT obj_description('public.phoenix_kit'::regclass)")
    marker
  end

  defp library_columns do
    query("""
    SELECT table_name, is_nullable, column_default
    FROM information_schema.columns
    WHERE table_schema = 'public' AND column_name = 'library_uuid'
      AND table_name IN ('phoenix_kit_files', 'phoenix_kit_media_folders', 'phoenix_kit_media_folder_links')
    ORDER BY table_name
    """)
  end

  defp folder_index do
    [[definition]] =
      query("""
      SELECT indexdef FROM pg_indexes
      WHERE schemaname = 'public' AND indexname = 'phoenix_kit_media_folders_name_parent_idx'
      """)

    definition
  end

  defp user! do
    [[uuid]] =
      query("""
      INSERT INTO public.phoenix_kit_users (email, hashed_password, inserted_at, updated_at)
      VALUES ('v202-#{System.unique_integer([:positive])}@example.com', 'x', NOW(), NOW())
      RETURNING uuid::text
      """)

    uuid
  end

  defp file!(user_uuid) do
    [[uuid]] =
      query(
        """
        INSERT INTO public.phoenix_kit_files
          (original_file_name, file_name, file_path, mime_type, file_type, ext, file_checksum,
           user_file_checksum, size, status, user_uuid, inserted_at, updated_at)
        VALUES ('a.png', 'a.png', 'x/a.png', 'image/png', 'image', 'png', $1, $1, 1, 'active',
                $2::text::uuid, NOW(), NOW())
        RETURNING uuid::text
        """,
        [Ecto.UUID.generate(), user_uuid]
      )

    uuid
  end

  defp folder!(name) do
    [[uuid]] =
      query(
        """
        INSERT INTO public.phoenix_kit_media_folders (name, inserted_at, updated_at)
        VALUES ($1, NOW(), NOW()) RETURNING uuid::text
        """,
        [name]
      )

    uuid
  end

  defp link!(folder_uuid, file_uuid) do
    query(
      """
      INSERT INTO public.phoenix_kit_media_folder_links (folder_uuid, file_uuid, inserted_at)
      VALUES ($1::text::uuid, $2::text::uuid, NOW())
      """,
      [folder_uuid, file_uuid]
    )
  end

  defp library_of(table, uuid) do
    [[library]] =
      query("SELECT library_uuid::text FROM public.#{table} WHERE uuid = $1::text::uuid", [uuid])

    library
  end

  test "down removes the partition; up puts what exists into Media and stamps the marker" do
    # V232's stacks and V203's members tables reference the libraries, so they go
    # first. The test runs in the sandbox transaction, which puts them back.
    run(V232.down_statements("public"))
    run(V203.down_statements("public"))
    run(V202.down_statements("public"))
    assert library_columns() == []
    refute folder_index() =~ "library_uuid"
    assert marker() == "201"

    user = user!()
    file = file!(user)
    folder = folder!("v202-folder")
    link!(folder, file)

    run(V202.up_statements("public"))

    assert marker() == "202"

    assert [
             ["phoenix_kit_files", "NO", default],
             ["phoenix_kit_media_folder_links", "NO", default],
             ["phoenix_kit_media_folders", "NO", default]
           ] = library_columns()

    assert default == "'#{@media}'::uuid"
    assert library_of("phoenix_kit_files", file) == @media
    assert library_of("phoenix_kit_media_folders", folder) == @media

    assert [[@media]] =
             query(
               "SELECT library_uuid::text FROM public.phoenix_kit_media_folder_links WHERE file_uuid = $1::text::uuid",
               [file]
             )

    assert folder_index() =~ "(library_uuid, name, COALESCE(parent_uuid"

    assert [["Media", "system", "site", true]] =
             query(
               "SELECT name, kind, visibility, is_default FROM public.phoenix_kit_storage_libraries WHERE uuid = $1::text::uuid",
               [@media]
             )
  end

  test "up is re-runnable" do
    run(V202.up_statements("public"))
    run(V202.up_statements("public"))

    assert length(library_columns()) == 3
    assert folder_index() =~ "library_uuid"
    assert marker() == "202"
  end

  test "a re-run gives a library that predates the slug column a slug from its name" do
    query("""
    INSERT INTO public.phoenix_kit_storage_libraries (name, kind, visibility)
    VALUES ('Brand Assets', 'system', 'site'), ('brand   assets!', 'system', 'site')
    """)

    run(V202.up_statements("public"))

    assert [["brand-assets"], ["brand-assets-2"]] =
             query("""
             SELECT slug FROM public.phoenix_kit_storage_libraries
             WHERE name IN ('Brand Assets', 'brand   assets!') ORDER BY slug
             """)

    assert [[nil]] =
             query(
               "SELECT slug FROM public.phoenix_kit_storage_libraries WHERE uuid = $1::text::uuid",
               [@media]
             )
  end

  test "a re-run does not give two libraries the same slug" do
    # `Foo` and `Foo!` both slugify to `foo`; `Foo-2` slugifies to the
    # disambiguator the second `foo` would otherwise take. A single ranked
    # update wrote `foo-2` twice and the unique index aborted the migration.
    query("""
    INSERT INTO public.phoenix_kit_storage_libraries (name, kind, visibility)
    VALUES ('Foo', 'system', 'site'), ('Foo!', 'system', 'site'), ('Foo-2', 'system', 'site')
    """)

    long_a = String.duplicate("a", 70)
    long_b = String.duplicate("a", 58) <> "zzz"

    query(
      """
      INSERT INTO public.phoenix_kit_storage_libraries (name, kind, visibility)
      VALUES ($1, 'system', 'site'), ($2, 'system', 'site')
      """,
      [long_a, long_b]
    )

    run(V202.up_statements("public"))

    # Which suffix lands on which row depends on uuid order. What must
    # hold is that the update finishes and the three slugs differ: the
    # old ranked update wrote `foo-2` twice and the unique index aborted.
    foo_slugs =
      query("""
      SELECT slug FROM public.phoenix_kit_storage_libraries
      WHERE name IN ('Foo', 'Foo!', 'Foo-2')
      """)
      |> Enum.map(fn [slug] -> slug end)

    assert length(foo_slugs) == 3
    assert Enum.uniq(foo_slugs) == foo_slugs
    assert "foo" in foo_slugs
    assert Enum.all?(foo_slugs, &String.starts_with?(&1, "foo"))

    slugs =
      query(
        """
        SELECT slug FROM public.phoenix_kit_storage_libraries
        WHERE name IN ($1, $2) ORDER BY slug
        """,
        [long_a, long_b]
      )

    assert length(slugs) == 2
    assert Enum.uniq(slugs) == slugs
    assert Enum.all?(slugs, fn [slug] -> String.starts_with?(slug, String.duplicate("a", 58)) end)
  end

  test "a writer that names no library lands in Media" do
    file = file!(user!())
    assert library_of("phoenix_kit_files", file) == @media
  end

  test "a folder name is unique per library, not site-wide" do
    [[other]] =
      query("""
      INSERT INTO public.phoenix_kit_storage_libraries (name, kind, visibility)
      VALUES ('Other #{System.unique_integer([:positive])}', 'system', 'site')
      RETURNING uuid::text
      """)

    name = "v202-same-#{System.unique_integer([:positive])}"
    folder!(name)

    query(
      "INSERT INTO public.phoenix_kit_media_folders (name, library_uuid, inserted_at, updated_at) VALUES ($1, $2::text::uuid, NOW(), NOW())",
      [name, other]
    )

    assert_raise Postgrex.Error, ~r/phoenix_kit_media_folders_name_parent_idx/, fn ->
      Repo.transaction(fn -> folder!(name) end)
    end
  end

  test "a folder link cannot name a library other than its file's" do
    [[other]] =
      query("""
      INSERT INTO public.phoenix_kit_storage_libraries (name, kind, visibility)
      VALUES ('Other #{System.unique_integer([:positive])}', 'system', 'site')
      RETURNING uuid::text
      """)

    file = file!(user!())
    folder = folder!("v202-link-#{System.unique_integer([:positive])}")

    assert_raise Postgrex.Error, ~r/phoenix_kit_media_folder_links_file_library_fkey/, fn ->
      Repo.transaction(fn ->
        query(
          "INSERT INTO public.phoenix_kit_media_folder_links (folder_uuid, file_uuid, library_uuid, inserted_at) VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, NOW())",
          [folder, file, other]
        )
      end)
    end
  end

  test "a library that still holds files cannot be deleted" do
    assert_raise Postgrex.Error, ~r/phoenix_kit_files_library_uuid_fkey/, fn ->
      file!(user!())

      Repo.transaction(fn ->
        query("DELETE FROM public.phoenix_kit_storage_libraries WHERE uuid = $1::text::uuid", [
          @media
        ])
      end)
    end
  end
end
