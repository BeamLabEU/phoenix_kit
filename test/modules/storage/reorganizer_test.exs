defmodule PhoenixKit.Modules.Storage.ReorganizerTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Reorganizer
  alias PhoenixKit.Users.Auth

  defmodule StubSource do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Storage.Reorganizer.Source

    @impl true
    def plan(_actor, opts), do: Keyword.get(opts, :stub_actions, [])
  end

  defmodule RaisingSource do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Storage.Reorganizer.Source

    @impl true
    def plan(_actor, _opts), do: raise("boom")
  end

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  defp create_folder!(attrs) do
    {:ok, folder} = Storage.create_folder(attrs)
    folder
  end

  defp create_file!(folder_uuid, status \\ "active") do
    n = System.unique_integer([:positive])

    {:ok, file} =
      Repo.insert(%StorageFile{
        original_file_name: "test_#{n}.jpg",
        file_name: "test_#{n}.jpg",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
        file_checksum: "sha256:test-#{n}",
        user_file_checksum: "user-sha256:test-#{n}",
        size: 1024,
        status: status,
        folder_uuid: folder_uuid,
        user_uuid: ensure_user!()
      })

    file
  end

  defp ensure_user! do
    case Process.get(:test_owner_user_uuid) do
      nil ->
        n = System.unique_integer([:positive])

        {:ok, user} =
          Auth.register_user(%{
            email: "reorganizer-test-#{n}@example.com",
            password: "ValidPassword123!"
          })

        Process.put(:test_owner_user_uuid, user.uuid)
        user.uuid

      uuid ->
        uuid
    end
  end

  defp run!(actions) do
    {:ok, report} =
      Reorganizer.run(nil, apply?: true, sources: [StubSource], stub_actions: actions)

    report
  end

  defp move_action(overrides) do
    Map.merge(
      %{
        source: "catalogue",
        kind: :item,
        label: "Tööpind [SKU-12]",
        op: :move,
        counts: {0, 0},
        on_conflict: :report
      },
      overrides
    )
  end

  # ---------------------------------------------------------------------
  # Cases
  # ---------------------------------------------------------------------

  test "moves and renames a legacy root folder into a target parent" do
    target = create_folder!(%{name: "Target"})
    folder = create_folder!(%{name: "x-legacy"})

    plan = [
      move_action(%{folder: folder, parent_uuid: target.uuid, name: "New", counts: {0, 0}})
    ]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :moved_renamed

    reloaded = Storage.get_folder(folder.uuid)
    assert reloaded.parent_uuid == target.uuid
    assert reloaded.name == "New"

    # Second run with a freshly-read folder (what a real Source's plan/2
    # would return on its next call) plans nothing — the folder already
    # sits at the wanted parent/name, so the engine filters it as a noop.
    second_plan = [
      move_action(%{folder: reloaded, parent_uuid: target.uuid, name: "New", counts: {0, 0}})
    ]

    {:ok, second} =
      Reorganizer.run(nil, apply?: true, sources: [StubSource], stub_actions: second_plan)

    assert second.actions == []
  end

  test "renames with a free suffix on a live name collision when on_conflict: :suffix" do
    target = create_folder!(%{name: "Target"})
    _existing = create_folder!(%{name: "New", parent_uuid: target.uuid})
    folder = create_folder!(%{name: "x-legacy"})

    plan = [
      move_action(%{
        folder: folder,
        parent_uuid: target.uuid,
        name: "New",
        counts: {0, 0},
        on_conflict: :suffix
      })
    ]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome in [:renamed, :moved_renamed]

    reloaded = Storage.get_folder(folder.uuid)
    assert reloaded.name == "New (2)"
    assert reloaded.parent_uuid == target.uuid
  end

  test "surfaces a conflict and leaves the folder untouched when on_conflict: :report" do
    target = create_folder!(%{name: "Target"})
    _existing = create_folder!(%{name: "New", parent_uuid: target.uuid})
    folder = create_folder!(%{name: "x-legacy"})

    plan = [
      move_action(%{
        folder: folder,
        parent_uuid: target.uuid,
        name: "New",
        counts: {0, 0},
        on_conflict: :report
      })
    ]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :conflict

    reloaded = Storage.get_folder(folder.uuid)
    assert reloaded.name == "x-legacy"
    assert reloaded.parent_uuid == nil
  end

  test "fails on a count mismatch and leaves the folder untouched" do
    target = create_folder!(%{name: "Target"})
    folder = create_folder!(%{name: "x-legacy"})
    create_file!(folder.uuid)

    plan = [
      move_action(%{folder: folder, parent_uuid: target.uuid, name: "New", counts: {0, 0}})
    ]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :failed
    assert action.error == {:count_mismatch, folder.uuid, {0, 0}, {1, 0}}

    reloaded = Storage.get_folder(folder.uuid)
    assert reloaded.name == "x-legacy"
    assert reloaded.parent_uuid == nil
  end

  test "counts a trashed file toward the folder's counts, same as an active one" do
    target = create_folder!(%{name: "Target"})
    folder = create_folder!(%{name: "x-legacy"})
    create_file!(folder.uuid, "trashed")

    # An action planned against a stale {0, 0} still fails — a trashed file
    # is still counted.
    mismatched = [
      move_action(%{folder: folder, parent_uuid: target.uuid, name: "New", counts: {0, 0}})
    ]

    report = run!(mismatched)
    [action] = report.actions

    assert action.outcome == :failed
    assert action.error == {:count_mismatch, folder.uuid, {0, 0}, {1, 0}}

    # The correct {1, 0} count (matching what a Source would have measured
    # at plan time) succeeds.
    matched = [
      move_action(%{folder: folder, parent_uuid: target.uuid, name: "New", counts: {1, 0}})
    ]

    report = run!(matched)
    [action] = report.actions

    assert action.outcome == :moved_renamed
  end

  test "rolls back when after_move returns {:error, _}" do
    target = create_folder!(%{name: "Target"})
    folder = create_folder!(%{name: "x-legacy"})

    plan = [
      move_action(%{
        folder: folder,
        parent_uuid: target.uuid,
        name: "New",
        counts: {0, 0},
        after_move: fn -> {:error, :boom} end
      })
    ]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :failed

    reloaded = Storage.get_folder(folder.uuid)
    assert reloaded.name == "x-legacy"
    assert reloaded.parent_uuid == nil
  end

  test "outcome is :backfilled when after_move succeeds" do
    target = create_folder!(%{name: "Target"})
    folder = create_folder!(%{name: "x-legacy"})

    plan = [
      move_action(%{
        folder: folder,
        parent_uuid: target.uuid,
        name: "New",
        counts: {0, 0},
        after_move: fn -> :ok end
      })
    ]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :backfilled

    reloaded = Storage.get_folder(folder.uuid)
    assert reloaded.parent_uuid == target.uuid
    assert reloaded.name == "New"
  end

  test "restores a trashed folder before moving it" do
    target = create_folder!(%{name: "Target"})
    folder = create_folder!(%{name: "x-legacy"})
    {:ok, _} = Storage.trash_folder(folder)
    trashed_folder = Storage.get_folder(folder.uuid)

    plan = [
      move_action(%{folder: trashed_folder, parent_uuid: target.uuid, counts: {0, 0}})
    ]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :moved

    reloaded = Storage.get_folder(folder.uuid)
    assert reloaded.trashed_at == nil
    assert reloaded.parent_uuid == target.uuid
  end

  test "trashes an empty folder and reports a non-empty one" do
    empty = create_folder!(%{name: "pending-empty"})
    non_empty = create_folder!(%{name: "pending-full"})
    create_file!(non_empty.uuid)

    plan = [
      %{source: "catalogue", kind: :pending, label: "pending-empty", op: :trash, folder: empty},
      %{
        source: "catalogue",
        kind: :pending,
        label: "pending-full",
        op: :trash,
        folder: non_empty
      }
    ]

    report = run!(plan)
    by_label = Map.new(report.actions, &{&1.label, &1})

    assert by_label["pending-empty"].outcome == :trashed
    assert Storage.get_folder(empty.uuid).trashed_at != nil

    assert by_label["pending-full"].outcome == :reported
    assert by_label["pending-full"].reason =~ "file"
    assert Storage.get_folder(non_empty.uuid).trashed_at == nil
  end

  test "a source that raises becomes one :report action and other sources still run" do
    target = create_folder!(%{name: "Target"})
    folder = create_folder!(%{name: "x-legacy"})

    stub_plan = [
      move_action(%{folder: folder, parent_uuid: target.uuid, name: "New", counts: {0, 0}})
    ]

    {:ok, report} =
      Reorganizer.run(nil,
        apply?: true,
        sources: [RaisingSource, StubSource],
        stub_actions: stub_plan
      )

    kinds = Enum.map(report.actions, & &1.kind)
    assert :source_error in kinds
    assert :item in kinds

    source_error_action = Enum.find(report.actions, &(&1.kind == :source_error))
    assert source_error_action.outcome == :reported

    moved_action = Enum.find(report.actions, &(&1.kind == :item))
    assert moved_action.outcome == :moved_renamed
  end

  test "apply?: false plans without writing" do
    target = create_folder!(%{name: "Target"})
    folder = create_folder!(%{name: "x-legacy"})

    plan = [
      move_action(%{folder: folder, parent_uuid: target.uuid, name: "New", counts: {0, 0}})
    ]

    {:ok, report} =
      Reorganizer.run(nil, apply?: false, sources: [StubSource], stub_actions: plan)

    assert report.applied? == false
    assert [%{op: :move}] = report.actions
    refute Map.has_key?(hd(report.actions), :outcome)

    reloaded = Storage.get_folder(folder.uuid)
    assert reloaded.name == "x-legacy"
    assert reloaded.parent_uuid == nil
  end

  test "format_report/1 includes a row for {source, kind} and conflict details" do
    target = create_folder!(%{name: "Target"})
    _existing = create_folder!(%{name: "New", parent_uuid: target.uuid})
    folder = create_folder!(%{name: "x-legacy"})

    plan = [
      move_action(%{
        folder: folder,
        parent_uuid: target.uuid,
        name: "New",
        counts: {0, 0},
        on_conflict: :report
      })
    ]

    report = run!(plan)
    text = Reorganizer.format_report(report)

    assert text =~ "catalogue item"
    assert text =~ "conflict"

    # Column headers are separately readable words, not run together
    # ("renamedbackfilledconflicts...") — each gets its own field width.
    assert text =~ " renamed "
    assert text =~ " backfilled "
  end

  test "format_report/1 includes a :trashed action in the details section on --apply" do
    empty = create_folder!(%{name: "pending-empty"})

    plan = [
      %{source: "catalogue", kind: :pending, label: "pending-empty", op: :trash, folder: empty}
    ]

    report = run!(plan)
    text = Reorganizer.format_report(report)

    assert text =~ "catalogue pending"
    assert text =~ "pending-empty"
    assert text =~ "trashed"
  end
end
