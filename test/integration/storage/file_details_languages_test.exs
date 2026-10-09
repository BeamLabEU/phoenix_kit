defmodule PhoenixKit.Integration.Storage.FileDetailsLanguagesTest do
  @moduledoc """
  `Storage.update_file_details_languages/3`: several languages' title, alt text
  and description in one held write — only the languages that changed, all or
  none, with tags and other metadata set in the same write.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth

  @opts [primary: "en"]

  defp file!(attrs \\ []) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Auth.register_user(%{
        "email" => "details-langs-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    Repo.insert!(
      struct!(
        %StorageFile{
          original_file_name: "d#{n}.jpg",
          file_name: "d#{n}.jpg",
          mime_type: "image/jpeg",
          file_type: "image",
          ext: "jpg",
          file_checksum: "sha256:dl-#{n}",
          user_file_checksum: "user-sha256:dl-#{n}",
          size: 10,
          status: "active",
          user_uuid: user.uuid
        },
        attrs
      )
    )
  end

  test "two languages are written in one save" do
    file = file!()

    assert {:ok, row} =
             Storage.update_file_details_languages(
               file,
               %{
                 "en" => %{"title" => "Harbour"},
                 "et" => %{"title" => "Sadam", "description" => "Paadid."}
               },
               @opts
             )

    assert row.data == %{
             "en" => %{"title" => "Harbour"},
             "et" => %{"title" => "Sadam", "description" => "Paadid."}
           }

    assert Repo.reload!(file).data == row.data
  end

  test "a language whose text did not change is left as the row holds it" do
    file = file!(data: %{"en" => %{"title" => "Harbour"}, "et" => %{"title" => "Sadam"}})

    # Another editor saved Estonian since this form loaded: a form that still
    # posts the English it showed must not carry a stale Estonian over it.
    {:ok, _} =
      Storage.update_file_details(file, %{"title" => "Sadam 2"}, lang: "et", primary: "en")

    assert {:ok, row} =
             Storage.update_file_details_languages(
               file,
               %{"en" => %{"title" => "Harbour"}, "et" => %{"title" => "Sadam 2"}},
               @opts
             )

    assert row.data["et"] == %{"title" => "Sadam 2"}
  end

  test "an invalid language saves none, and names the language" do
    file = file!(data: %{"en" => %{"title" => "Harbour"}})

    assert {:error, {"et", %Ecto.Changeset{} = changeset}} =
             Storage.update_file_details_languages(
               file,
               %{
                 "en" => %{"title" => "Changed"},
                 "et" => %{"title" => String.duplicate("a", 256)}
               },
               @opts
             )

    assert %{title: [_]} = errors_on(changeset)
    assert Repo.reload!(file).data == %{"en" => %{"title" => "Harbour"}}
  end

  test "other metadata is set in the same write, with no language changed" do
    file = file!(metadata: %{"rotation" => 90})

    assert {:ok, row} =
             Storage.update_file_details_languages(file, %{},
               primary: "en",
               metadata: %{"tags" => ["a", "b"]}
             )

    assert row.metadata == %{"rotation" => 90, "tags" => ["a", "b"]}
  end

  test "tags and a language land together, and the text keys cannot be set through metadata" do
    file = file!()

    assert {:ok, row} =
             Storage.update_file_details_languages(
               file,
               %{"en" => %{"title" => "Harbour"}},
               primary: "en",
               metadata: %{"tags" => ["sea"], "title" => "sneaky"}
             )

    assert row.metadata["tags"] == ["sea"]
    assert row.metadata["title"] == "Harbour"
  end

  test "a file that is gone is not found" do
    file = file!()
    Repo.delete!(file)

    assert {:error, :not_found} =
             Storage.update_file_details_languages(file, %{"en" => %{"title" => "x"}}, @opts)
  end
end
