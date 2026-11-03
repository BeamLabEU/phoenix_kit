defmodule PhoenixKit.Modules.Storage.ProcessFileJobFailureTest do
  @moduledoc """
  A file whose processing never succeeds does not stay "processing" for good.

  The upload leaves a file `"processing"` and only a successful run of
  `ProcessFileJob` makes it `"active"`. When the original cannot be read, or
  the run raises, every attempt failed and nothing ever changed the status, so
  the file showed as processing in every view indefinitely. The last failing
  attempt now marks it `"failed"`, which the interface and the reconciler
  already handle.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ProcessFileJob
  alias PhoenixKit.Users.Auth

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "job-failure-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp file!(status \\ "processing") do
    user = user!()

    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "broken.png",
        file_name: "broken.png",
        file_path: "x/broken.png",
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: status,
        user_uuid: user.uuid
      })

    file
  end

  defp job(file, attempt, max \\ 3) do
    %Oban.Job{
      args: %{"file_uuid" => file.uuid, "filename" => "broken.png"},
      attempt: attempt,
      max_attempts: max
    }
  end

  defp status(file), do: Storage.get_file(file.uuid).status

  test "the last failing attempt marks a processing file failed" do
    file = file!()
    Storage.subscribe_to_file_events()

    assert {:error, _} = ProcessFileJob.perform(job(file, 3))

    assert status(file) == "failed"
    uuid = file.uuid
    assert_receive {:phoenix_kit_file_processed, ^uuid}, 1_000
  end

  test "an earlier attempt leaves it processing, so the retry has something to fix" do
    file = file!()

    assert {:error, _} = ProcessFileJob.perform(job(file, 1))
    assert {:error, _} = ProcessFileJob.perform(job(file, 2))

    assert status(file) == "processing"
  end

  test "a file that is already active is never marked failed" do
    file = file!("active")

    assert {:error, _} = ProcessFileJob.perform(job(file, 3))

    assert status(file) == "active"
  end

  test "a file that is gone is not a crash" do
    file = file!()
    {:ok, _} = PhoenixKit.RepoHelper.repo().delete(file)

    assert {:error, :file_not_found} = ProcessFileJob.perform(job(file, 3))
  end
end
