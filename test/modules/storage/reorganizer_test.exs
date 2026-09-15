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

  defmodule ThrowingSource do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Storage.Reorganizer.Source

    @impl true
    def plan(_actor, _opts), do: throw(:boom)
  end

  defmodule ExitingSource do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Storage.Reorganizer.Source

    @impl true
    def plan(_actor, _opts), do: exit(:boom)
  end

  defmodule NonListSource do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Storage.Reorganizer.Source

    @impl true
    def plan(_actor, _opts), do: :not_a_list
  end

  defmodule DisabledHostModule do
    @moduledoc false
    def module_key, do: "disabled_reorganizer_module"
    def module_name, do: "Disabled Reorganizer Module"
    def enabled?, do: false
    def enable_system, do: :ok
    def disable_system, do: :ok
    def media_reorganizer, do: DisabledHostModule.MediaReorganizer

    defmodule MediaReorganizer do
      @moduledoc false
      @behaviour PhoenixKit.Modules.Storage.Reorganizer.Source

      @impl true
      def plan(_actor, _opts) do
        [
          %{
            source: "disabled_reorganizer_module",
            kind: :item,
            label: "should never be planned",
            op: :report
          }
        ]
      end
    end
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

  test "folder already in place + after_move still backfills the pointer" do
    folder = create_folder!(%{name: "x-legacy"})

    plan = [
      move_action(%{folder: folder, counts: {0, 0}, after_move: fn -> :ok end})
    ]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :backfilled

    reloaded = Storage.get_folder(folder.uuid)
    assert reloaded.parent_uuid == nil
    assert reloaded.name == "x-legacy"

    # A second plan without after_move (a real Source wouldn't emit it again
    # once the pointer is backfilled) is a true noop — nothing to plan.
    second_plan = [move_action(%{folder: reloaded, counts: {0, 0}})]

    {:ok, second} =
      Reorganizer.run(nil, apply?: true, sources: [StubSource], stub_actions: second_plan)

    assert second.actions == []
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

  # ---------------------------------------------------------------------
  # B2/M1 — apply_one/1 and plan/2 never halt the run
  # ---------------------------------------------------------------------

  test "a source that throws becomes one :source_error :report action and other sources still run" do
    target = create_folder!(%{name: "Target"})
    folder = create_folder!(%{name: "x-legacy"})

    stub_plan = [
      move_action(%{folder: folder, parent_uuid: target.uuid, name: "New", counts: {0, 0}})
    ]

    {:ok, report} =
      Reorganizer.run(nil,
        apply?: true,
        sources: [ThrowingSource, StubSource],
        stub_actions: stub_plan
      )

    source_error_action = Enum.find(report.actions, &(&1.kind == :source_error))
    assert source_error_action.outcome == :reported

    moved_action = Enum.find(report.actions, &(&1.kind == :item))
    assert moved_action.outcome == :moved_renamed
  end

  test "a source that exits becomes one :source_error :report action and other sources still run" do
    {:ok, report} =
      Reorganizer.run(nil, apply?: true, sources: [ExitingSource])

    [action] = report.actions
    assert action.kind == :source_error
    assert action.outcome == :reported
  end

  test "a source returning a non-list becomes one :source_error :report action" do
    {:ok, report} =
      Reorganizer.run(nil, apply?: true, sources: [NonListSource])

    [action] = report.actions
    assert action.kind == :source_error
    assert action.outcome == :reported
  end

  test "an invalid action from a source becomes one :invalid_action :report, other actions in the same source still run" do
    target = create_folder!(%{name: "Target"})
    folder = create_folder!(%{name: "x-legacy"})

    good = move_action(%{folder: folder, parent_uuid: target.uuid, name: "New", counts: {0, 0}})
    bad = %{kind: :item, label: "missing required keys", op: :move}

    {:ok, report} =
      Reorganizer.run(nil,
        apply?: true,
        sources: [StubSource],
        stub_actions: [good, bad]
      )

    invalid = Enum.find(report.actions, &(&1.kind == :invalid_action))
    assert invalid.outcome == :reported

    moved = Enum.find(report.actions, &(&1.kind == :item))
    assert moved.outcome == :moved_renamed
  end

  test "after_move raising an exception is caught and the action fails without losing other actions" do
    target = create_folder!(%{name: "Target"})
    ok_folder = create_folder!(%{name: "x-legacy-ok"})
    raising_folder = create_folder!(%{name: "x-legacy-raise"})

    plan = [
      move_action(%{
        folder: ok_folder,
        kind: :ok_item,
        parent_uuid: target.uuid,
        counts: {0, 0}
      }),
      move_action(%{
        folder: raising_folder,
        kind: :raising_item,
        parent_uuid: target.uuid,
        counts: {0, 0},
        after_move: fn -> raise "boom in after_move" end
      })
    ]

    report = run!(plan)

    ok_action = Enum.find(report.actions, &(&1.kind == :ok_item))
    assert ok_action.outcome == :moved

    failed_action = Enum.find(report.actions, &(&1.kind == :raising_item))
    assert failed_action.outcome == :failed

    reloaded = Storage.get_folder(raising_folder.uuid)
    assert reloaded.parent_uuid == nil
  end

  test "after_move returning {:ok, _} backfills successfully" do
    target = create_folder!(%{name: "Target"})
    folder = create_folder!(%{name: "x-legacy"})

    plan = [
      move_action(%{
        folder: folder,
        parent_uuid: target.uuid,
        counts: {0, 0},
        after_move: fn -> {:ok, :whatever} end
      })
    ]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :backfilled
  end

  test "after_move returning an unexpected value fails the action" do
    target = create_folder!(%{name: "Target"})
    folder = create_folder!(%{name: "x-legacy"})

    plan = [
      move_action(%{
        folder: folder,
        parent_uuid: target.uuid,
        counts: {0, 0},
        after_move: fn -> :something_else end
      })
    ]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :failed
    assert action.error == {:bad_after_move_return, :something_else}
  end

  # ---------------------------------------------------------------------
  # M2 — Action field types are validated (a bad type never reaches apply)
  # ---------------------------------------------------------------------

  test "an action with a non-binary label becomes one :invalid_action report instead of crashing the run" do
    target = create_folder!(%{name: "Target"})
    good_folder = create_folder!(%{name: "x-legacy-good"})

    good = move_action(%{folder: good_folder, parent_uuid: target.uuid, counts: {0, 0}})
    bad = move_action(%{label: {:bad, 1}, folder: nil})

    {:ok, report} =
      Reorganizer.run(nil, apply?: true, sources: [StubSource], stub_actions: [good, bad])

    invalid = Enum.find(report.actions, &(&1.kind == :invalid_action))
    assert invalid.outcome == :reported

    moved = Enum.find(report.actions, &(&1.kind == :item))
    assert moved.outcome == :moved
  end

  test "an action with a non-atom kind or non-binary source becomes one :invalid_action report" do
    bad_kind = move_action(%{kind: "not_an_atom"})
    bad_source = move_action(%{source: :not_a_string})

    {:ok, report} =
      Reorganizer.run(nil,
        apply?: true,
        sources: [StubSource],
        stub_actions: [bad_kind, bad_source]
      )

    assert length(report.actions) == 2
    assert Enum.all?(report.actions, &(&1.kind == :invalid_action and &1.outcome == :reported))
  end

  # ---------------------------------------------------------------------
  # M3 — unknown action keys are dropped with a warning, never raised
  # ---------------------------------------------------------------------

  test "an unknown action key is dropped with a warning instead of crashing the plan" do
    target = create_folder!(%{name: "Target"})
    folder = create_folder!(%{name: "x-legacy"})

    plan = [
      move_action(%{
        folder: folder,
        parent_uuid: target.uuid,
        counts: {0, 0},
        totally_unknown_future_key: "from a newer module"
      })
    ]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :moved
    refute Map.has_key?(action, :totally_unknown_future_key)
  end

  # ---------------------------------------------------------------------
  # M4 — counts: nil is a failure, not a silently-disabled guard
  # ---------------------------------------------------------------------

  test "counts: nil fails the move instead of silently skipping the guard" do
    target = create_folder!(%{name: "Target"})
    folder = create_folder!(%{name: "x-legacy"})

    plan = [move_action(%{folder: folder, parent_uuid: target.uuid, counts: nil})]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :failed
    assert action.error == {:counts_missing, folder.uuid}

    reloaded = Storage.get_folder(folder.uuid)
    assert reloaded.parent_uuid == nil
  end

  # ---------------------------------------------------------------------
  # M5 — :trash requires 0 files, 0 links AND 0 live child folders
  # ---------------------------------------------------------------------

  test "reports instead of trashing a folder that still has a live child folder" do
    parent = create_folder!(%{name: "pending-with-child"})
    _child = create_folder!(%{name: "child", parent_uuid: parent.uuid})

    plan = [
      %{
        source: "catalogue",
        kind: :pending,
        label: "pending-with-child",
        op: :trash,
        folder: parent
      }
    ]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :reported
    assert action.reason =~ "child folder"
    assert Storage.get_folder(parent.uuid).trashed_at == nil
  end

  test "trashes a folder whose only child folders are already trashed" do
    parent = create_folder!(%{name: "pending-with-trashed-child"})
    child = create_folder!(%{name: "child", parent_uuid: parent.uuid})
    {:ok, _} = Storage.trash_folder(child)

    plan = [
      %{
        source: "catalogue",
        kind: :pending,
        label: "pending-with-trashed-child",
        op: :trash,
        folder: parent
      }
    ]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :trashed
  end

  test "trashing an already-trashed folder is reported instead of re-trashed" do
    folder = create_folder!(%{name: "pending-already-trashed"})
    {:ok, _} = Storage.trash_folder(folder)
    trashed_folder = Storage.get_folder(folder.uuid)
    original_trashed_at = trashed_folder.trashed_at

    plan = [
      %{
        source: "catalogue",
        kind: :pending,
        label: "pending-already-trashed",
        op: :trash,
        folder: trashed_folder
      }
    ]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :reported
    assert action.reason =~ "already trashed"
    assert Storage.get_folder(folder.uuid).trashed_at == original_trashed_at
  end

  # ---------------------------------------------------------------------
  # M6 — a trashed folder is never a noop; restoring it is :restored
  # ---------------------------------------------------------------------

  test "restoring a trashed folder that already sits at the wanted parent/name is outcome :restored" do
    folder = create_folder!(%{name: "x-legacy"})
    {:ok, _} = Storage.trash_folder(folder)
    trashed_folder = Storage.get_folder(folder.uuid)

    plan = [move_action(%{folder: trashed_folder, counts: {0, 0}})]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :restored

    reloaded = Storage.get_folder(folder.uuid)
    assert reloaded.trashed_at == nil
  end

  test "a trashed folder already in place is planned (not filtered as a noop)" do
    folder = create_folder!(%{name: "x-legacy"})
    {:ok, _} = Storage.trash_folder(folder)
    trashed_folder = Storage.get_folder(folder.uuid)

    plan = [move_action(%{folder: trashed_folder, counts: {0, 0}})]

    {:ok, report} =
      Reorganizer.run(nil, apply?: false, sources: [StubSource], stub_actions: plan)

    assert report.actions != []
  end

  # ---------------------------------------------------------------------
  # M7 — moving into a trashed or missing target parent fails clearly
  # ---------------------------------------------------------------------

  test "moving into a trashed target parent fails instead of silently succeeding" do
    target = create_folder!(%{name: "Target"})
    {:ok, _} = Storage.trash_folder(target)
    folder = create_folder!(%{name: "x-legacy"})

    plan = [move_action(%{folder: folder, parent_uuid: target.uuid, counts: {0, 0}})]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :failed
    assert action.error == {:target_parent_trashed, target.uuid}

    reloaded = Storage.get_folder(folder.uuid)
    assert reloaded.parent_uuid == nil
  end

  test "moving into a missing target parent fails instead of silently succeeding" do
    folder = create_folder!(%{name: "x-legacy"})
    missing_parent_uuid = Ecto.UUID.generate()

    plan = [move_action(%{folder: folder, parent_uuid: missing_parent_uuid, counts: {0, 0}})]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :failed
    assert action.error == {:target_parent_missing, missing_parent_uuid}
  end

  test "moving a folder under its own descendant fails with :cycle instead of corrupting the tree" do
    parent = create_folder!(%{name: "Parent"})
    child = create_folder!(%{name: "Child", parent_uuid: parent.uuid})

    plan = [move_action(%{folder: parent, parent_uuid: child.uuid, counts: {0, 0}})]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :failed
    assert action.error == :cycle

    reloaded = Storage.get_folder(parent.uuid)
    assert reloaded.parent_uuid == nil
  end

  test "after_move's own write is rolled back together with the folder move when a later step fails" do
    target = create_folder!(%{name: "Target"})
    folder = create_folder!(%{name: "x-legacy"})
    marker = create_folder!(%{name: "marker-not-yet-renamed"})

    plan = [
      move_action(%{
        folder: folder,
        parent_uuid: target.uuid,
        # counts is {0, 0} at plan time. after_move renames `marker` (a real
        # write) and then adds a file to `folder`, so the post-after_move
        # verify_counts re-check (same expected {0, 0}) fails — the whole
        # transaction rolls back, taking both the folder move AND
        # after_move's own write with it.
        counts: {0, 0},
        after_move: fn ->
          {:ok, _} = Storage.update_folder(marker, %{name: "marker-renamed-by-after-move"})
          create_file!(folder.uuid)
          :ok
        end
      })
    ]

    report = run!(plan)
    [action] = report.actions

    assert action.outcome == :failed
    assert {:count_mismatch, _folder_uuid, {0, 0}, {1, 0}} = action.error

    reloaded_folder = Storage.get_folder(folder.uuid)
    assert reloaded_folder.parent_uuid == nil

    reloaded_marker = Storage.get_folder(marker.uuid)
    assert reloaded_marker.name == "marker-not-yet-renamed"
  end

  # ---------------------------------------------------------------------
  # M8 — dry-run detail lines show the parent/name transition
  # ---------------------------------------------------------------------

  test "dry-run detail line shows the from/to parent names and the old/new folder name" do
    origin = create_folder!(%{name: "Origin"})
    target = create_folder!(%{name: "Target"})
    folder = create_folder!(%{name: "x-legacy", parent_uuid: origin.uuid})

    plan = [
      move_action(%{folder: folder, parent_uuid: target.uuid, name: "New", counts: {0, 0}})
    ]

    {:ok, report} =
      Reorganizer.run(nil, apply?: false, sources: [StubSource], stub_actions: plan)

    text = Reorganizer.format_report(report)

    assert text =~ "[catalogue/item] move"
    assert text =~ "Origin → Target"
    assert text =~ "name \"x-legacy\" → \"New\""
  end

  test "dry-run detail line shows root when the folder has no current parent" do
    target = create_folder!(%{name: "Target"})
    folder = create_folder!(%{name: "x-legacy"})

    plan = [move_action(%{folder: folder, parent_uuid: target.uuid, counts: {0, 0}})]

    {:ok, report} =
      Reorganizer.run(nil, apply?: false, sources: [StubSource], stub_actions: plan)

    text = Reorganizer.format_report(report)

    assert text =~ "root → Target"
  end

  # ---------------------------------------------------------------------
  # M9 — disabled module's Source is skipped by sources: :all
  # ---------------------------------------------------------------------

  test "a disabled module's Source is skipped by sources: :all" do
    PhoenixKit.ModuleRegistry.register(DisabledHostModule)
    on_exit(fn -> PhoenixKit.ModuleRegistry.unregister(DisabledHostModule) end)

    plan = Reorganizer.plan(nil, sources: :all)

    refute Enum.any?(plan, &(&1.source == "disabled_reorganizer_module"))
  end
end
