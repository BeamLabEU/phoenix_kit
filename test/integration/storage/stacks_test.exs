defmodule PhoenixKit.Modules.Storage.StacksTest do
  @moduledoc """
  Stacks (V232) and dates set by a person, against the database: making a stack and
  its order, merging stacks, who may, taking files out, the cover, the title and
  description, and moving files in time together (`ManualDate`), including the way
  back to a file's own date.
  """

  use PhoenixKit.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.{FileStack, Libraries, ManualDate, Stacks}
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKit.Users.Auth.Scope

  setup do
    {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
    {:ok, _} = Settings.update_setting("storage_user_library_limit", "3")

    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{name: "Stackers #{n}"})
    {:ok, _} = Permissions.grant_permission(role.uuid, "storage")
    {:ok, _} = Permissions.grant_permission(role.uuid, "storage.create_library")

    # The first account registered may become the Owner, who may do anything.
    _first = user!(nil)

    owner = user!(role)
    {:ok, library} = Libraries.create_user_library(scope(owner), %{"name" => "Lib #{n}"})

    Storage.subscribe_to_file_changes()

    %{role: role, owner: owner, library: library}
  end

  defp user!(role) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "stacks-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    if role, do: {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  defp scope(user), do: Scope.for_user(Repo.get!(Auth.User, user.uuid))

  defp file!(user, library, name, taken_at \\ nil, extra \\ %{}) do
    attrs =
      %{
        original_file_name: name,
        file_name: name,
        file_path: "x/#{name}",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: "active",
        user_uuid: user.uuid,
        library_uuid: library.uuid
      }
      |> Map.merge(dated(taken_at))
      |> Map.merge(extra)

    {:ok, file} = Storage.create_file(attrs)
    file
  end

  defp dated(nil), do: %{}

  defp dated(%NaiveDateTime{} = local) do
    %{
      taken_at: DateTime.from_naive!(local, "Etc/UTC"),
      taken_on: NaiveDateTime.to_date(local),
      taken_at_source: "exif"
    }
  end

  defp reload(file), do: Repo.get!(StorageFile, file.uuid)
  defp order_of(stack), do: Enum.map(Stacks.files(stack.uuid), & &1.original_file_name)

  describe "making a stack" do
    test "orders by capture date, then by name with numbers read as numbers", ctx do
      a = file!(ctx.owner, ctx.library, "page 10.jpg", ~N[2026-11-11 09:00:00])
      b = file!(ctx.owner, ctx.library, "page 2.jpg", ~N[2026-11-11 09:00:00])
      c = file!(ctx.owner, ctx.library, "earlier.jpg", ~N[2026-11-11 08:00:00])
      d = file!(ctx.owner, ctx.library, "undated.jpg")

      assert {:ok, %FileStack{} = stack} =
               Stacks.create([a.uuid, b.uuid, c.uuid, d.uuid], scope(ctx.owner), %{
                 title: "  Lease  "
               })

      assert stack.title == "Lease"
      assert stack.library_uuid == ctx.library.uuid
      assert stack.created_by_uuid == ctx.owner.uuid
      assert order_of(stack) == ["earlier.jpg", "page 2.jpg", "page 10.jpg", "undated.jpg"]
      assert reload(c).stack_position == 0

      assert_receive {:phoenix_kit_files_changed, uuids}
      assert Enum.sort(uuids) == Enum.sort([a.uuid, b.uuid, c.uuid, d.uuid])
    end

    test "a stack chosen with more files is merged into one new stack, keeping its text", ctx do
      [a, b, c] =
        for {name, at} <- [
              {"a.jpg", ~N[2026-01-01 10:00:00]},
              {"b.jpg", ~N[2026-01-01 10:01:00]},
              {"c.jpg", ~N[2026-01-01 09:00:00]}
            ],
            do: file!(ctx.owner, ctx.library, name, at)

      {:ok, old} = Stacks.create([a.uuid, b.uuid], scope(ctx.owner), %{title: "Receipts"})

      # Only one file of the old stack is named: the whole stack comes along, in its order
      # and with its cover; the earlier c goes in after the cover. No title given (nil, as
      # the timeline's dialog sends for an empty box) keeps the old one.
      {:ok, merged} = Stacks.create([a.uuid, c.uuid], scope(ctx.owner), %{title: nil})

      assert order_of(merged) == ["a.jpg", "c.jpg", "b.jpg"]
      assert merged.title == "Receipts"
      assert Stacks.get(old.uuid) == nil

      # Text given now wins over the old stack's.
      d = file!(ctx.owner, ctx.library, "d.jpg", ~N[2026-01-01 11:00:00])
      {:ok, again} = Stacks.create([d.uuid, c.uuid], scope(ctx.owner), %{title: "New"})
      assert again.title == "New"
      assert length(Stacks.files(again.uuid)) == 4
    end

    test "the order given, when asked to keep it", ctx do
      a = file!(ctx.owner, ctx.library, "a.jpg", ~N[2026-01-01 10:00:00])
      b = file!(ctx.owner, ctx.library, "b.jpg", ~N[2026-01-01 09:00:00])

      {:ok, stack} = Stacks.create([a.uuid, b.uuid], scope(ctx.owner), %{}, keep_order: true)
      assert order_of(stack) == ["a.jpg", "b.jpg"]
    end

    test "refusals", ctx do
      a = file!(ctx.owner, ctx.library, "a.jpg")
      b = file!(ctx.owner, ctx.library, "b.jpg")

      assert {:error, :too_few} = Stacks.create([a.uuid], scope(ctx.owner))
      assert {:error, :too_few} = Stacks.create([a.uuid, a.uuid], scope(ctx.owner))

      assert {:error, :not_found} =
               Stacks.create([a.uuid, Ecto.UUID.generate()], scope(ctx.owner))

      assert {:error, :not_found} = Stacks.create([a.uuid, "nonsense"], scope(ctx.owner))

      {:ok, other} = Libraries.create_user_library(scope(ctx.owner), %{"name" => "Other"})
      elsewhere = file!(ctx.owner, other, "e.jpg")

      assert {:error, :mixed_libraries} =
               Stacks.create([a.uuid, elsewhere.uuid], scope(ctx.owner))

      {:ok, _} = Storage.trash_file(b)
      assert {:error, :not_stackable} = Stacks.create([a.uuid, b.uuid], scope(ctx.owner))

      doc = file!(ctx.owner, ctx.library, "doc.pdf", nil, %{file_type: "document"})
      assert {:error, :not_stackable} = Stacks.create([a.uuid, doc.uuid], scope(ctx.owner))

      c = file!(ctx.owner, ctx.library, "c.jpg")
      assert {:error, :forbidden} = Stacks.create([a.uuid, c.uuid], scope(user!(nil)))
      assert {:error, :forbidden} = Stacks.create([a.uuid, c.uuid], nil)

      assert Repo.aggregate(from(f in StorageFile, where: not is_nil(f.stack_uuid)), :count) == 0
      refute_receive {:phoenix_kit_files_changed, _}
    end

    test "too many files", ctx do
      files = for i <- 0..Stacks.max_files(), do: file!(ctx.owner, ctx.library, "p#{i}.jpg")
      assert {:error, :too_many} = Stacks.create(Enum.map(files, & &1.uuid), scope(ctx.owner))
    end

    test "a contributor stacks their own uploads, not someone else's", ctx do
      contributor = user!(nil)

      {:ok, _} =
        Libraries.add_member(scope(ctx.owner), ctx.library, contributor.email, "contributor")

      mine = for n <- ["m1.jpg", "m2.jpg"], do: file!(contributor, ctx.library, n)
      theirs = file!(ctx.owner, ctx.library, "o.jpg")

      assert {:ok, _} = Stacks.create(Enum.map(mine, & &1.uuid), scope(contributor))

      assert {:error, :forbidden} =
               Stacks.create([hd(mine).uuid, theirs.uuid], scope(contributor))

      viewer = user!(nil)
      {:ok, _} = Libraries.add_member(scope(ctx.owner), ctx.library, viewer.email, "viewer")
      assert {:error, :forbidden} = Stacks.create([theirs.uuid, hd(mine).uuid], scope(viewer))
    end
  end

  describe "changing a stack" do
    setup ctx do
      files =
        for {name, i} <- Enum.with_index(["p1.jpg", "p2.jpg", "p3.jpg"]),
            do: file!(ctx.owner, ctx.library, name, NaiveDateTime.add(~N[2026-02-01 12:00:00], i))

      {:ok, stack} = Stacks.create(Enum.map(files, & &1.uuid), scope(ctx.owner), %{title: "T"})
      assert_receive {:phoenix_kit_files_changed, _}
      Map.put(ctx, :files, files) |> Map.put(:stack, stack)
    end

    test "a file taken out stays a file; a stack left with one is taken apart", ctx do
      [p1, p2, p3] = ctx.files

      assert {:ok, [uuid]} = Stacks.remove(p2.uuid, scope(ctx.owner))
      assert uuid == p2.uuid
      assert reload(p2).stack_uuid == nil
      assert order_of(ctx.stack) == ["p1.jpg", "p3.jpg"]
      assert_receive {:phoenix_kit_files_changed, [_]}

      assert {:ok, gone} = Stacks.remove(p3.uuid, scope(ctx.owner))
      assert Enum.sort(gone) == Enum.sort([p1.uuid, p3.uuid])
      assert reload(p1).stack_uuid == nil
      assert Stacks.get(ctx.stack.uuid) == nil

      assert {:error, :not_found} = Stacks.remove(p1.uuid, scope(ctx.owner))
    end

    test "a cover moves to the front and the rest keep their order", ctx do
      [_p1, _p2, p3] = ctx.files

      assert {:ok, %FileStack{}} = Stacks.make_cover(p3.uuid, scope(ctx.owner))
      assert order_of(ctx.stack) == ["p3.jpg", "p1.jpg", "p2.jpg"]
      assert_receive {:phoenix_kit_files_changed, uuids}
      assert length(uuids) == 3

      # Already the cover: nothing moves.
      assert {:ok, _} = Stacks.make_cover(p3.uuid, scope(ctx.owner))
      assert order_of(ctx.stack) == ["p3.jpg", "p1.jpg", "p2.jpg"]
    end

    test "unstacking leaves the files where they are and forgets the text", ctx do
      assert {:ok, uuids} = Stacks.unstack(ctx.stack.uuid, scope(ctx.owner))
      assert length(uuids) == 3
      assert Stacks.get(ctx.stack.uuid) == nil
      assert Enum.all?(ctx.files, &is_nil(reload(&1).stack_uuid))
      assert Enum.all?(ctx.files, &(reload(&1).taken_at == &1.taken_at))
      assert {:error, :not_found} = Stacks.unstack(ctx.stack.uuid, scope(ctx.owner))
    end

    test "title and description: changed, cleared, and too long", ctx do
      assert {:ok, stack} =
               Stacks.update(
                 ctx.stack.uuid,
                 %{"title" => "Lease 1985", "description" => "Signed."},
                 scope(ctx.owner)
               )

      assert {stack.title, stack.description} == {"Lease 1985", "Signed."}

      assert {:ok, stack} = Stacks.update(ctx.stack.uuid, %{title: "  "}, scope(ctx.owner))
      assert stack.title == nil
      assert stack.description == "Signed."

      long = String.duplicate("x", FileStack.max_title() + 1)

      assert {:error, %Ecto.Changeset{}} =
               Stacks.update(ctx.stack.uuid, %{title: long}, scope(ctx.owner))

      assert {:error, :forbidden} =
               Stacks.update(ctx.stack.uuid, %{title: "x"}, scope(user!(nil)))
    end

    test "nobody else changes it", ctx do
      stranger = scope(user!(nil))
      [p1 | _] = ctx.files
      assert {:error, :forbidden} = Stacks.unstack(ctx.stack.uuid, stranger)
      assert {:error, :forbidden} = Stacks.make_cover(p1.uuid, stranger)
      assert {:error, :forbidden} = Stacks.remove(p1.uuid, stranger)
      assert length(Stacks.files(ctx.stack.uuid)) == 3
    end

    test "files added go in among the others by date, and the cover stays", ctx do
      [_p1, _p2, p3] = ctx.files
      {:ok, _} = Stacks.make_cover(p3.uuid, scope(ctx.owner))
      assert_receive {:phoenix_kit_files_changed, _}

      before = file!(ctx.owner, ctx.library, "before.jpg", ~N[2026-02-01 11:00:00])
      later = file!(ctx.owner, ctx.library, "later.jpg", ~N[2026-02-01 13:00:00])

      assert {:ok, %FileStack{} = stack} =
               Stacks.add(ctx.stack.uuid, [later.uuid, before.uuid], scope(ctx.owner))

      assert stack.uuid == ctx.stack.uuid
      assert order_of(stack) == ["p3.jpg", "before.jpg", "p1.jpg", "p2.jpg", "later.jpg"]
      assert_receive {:phoenix_kit_files_changed, uuids}
      assert length(uuids) == 5

      # One already in it: nothing changes, nothing is announced.
      assert {:ok, _} = Stacks.add(ctx.stack.uuid, [before.uuid], scope(ctx.owner))
      assert order_of(stack) == ["p3.jpg", "before.jpg", "p1.jpg", "p2.jpg", "later.jpg"]
      refute_receive {:phoenix_kit_files_changed, _}, 50
    end

    test "a file of another stack brings that stack, which goes, and its text fills gaps",
         ctx do
      q1 = file!(ctx.owner, ctx.library, "q1.jpg", ~N[2026-02-01 12:30:00])
      q2 = file!(ctx.owner, ctx.library, "q2.jpg", ~N[2026-02-01 12:31:00])

      {:ok, other} =
        Stacks.create([q1.uuid, q2.uuid], scope(ctx.owner), %{title: "Q", description: "Both"})

      assert {:ok, stack} = Stacks.add(ctx.stack.uuid, [q2.uuid], scope(ctx.owner))
      assert order_of(stack) == ["p1.jpg", "p2.jpg", "p3.jpg", "q1.jpg", "q2.jpg"]
      # Its own title stays; the description it had none of comes along.
      assert {stack.title, stack.description} == {"T", "Both"}
      assert Stacks.get(other.uuid) == nil
    end

    test "adding: refusals", ctx do
      {:ok, elsewhere} =
        Libraries.create_user_library(scope(ctx.owner), %{
          "name" => "Else #{System.unique_integer([:positive])}"
        })

      single = file!(ctx.owner, ctx.library, "single.jpg", ~N[2026-02-01 12:10:00])
      far = file!(ctx.owner, elsewhere, "far.jpg", ~N[2026-02-01 12:10:00])

      assert {:error, :not_found} =
               Stacks.add(Ecto.UUID.generate(), [single.uuid], scope(ctx.owner))

      assert {:error, :not_found} = Stacks.add(ctx.stack.uuid, [], scope(ctx.owner))
      assert {:error, :mixed_libraries} = Stacks.add(ctx.stack.uuid, [far.uuid], scope(ctx.owner))
      assert {:error, :forbidden} = Stacks.add(ctx.stack.uuid, [single.uuid], scope(user!(nil)))

      {:ok, _} = Storage.trash_file(single)

      assert {:error, :not_stackable} =
               Stacks.add(ctx.stack.uuid, [single.uuid], scope(ctx.owner))

      assert length(Stacks.files(ctx.stack.uuid)) == 3
    end
  end

  test "names sort with their numbers read as numbers" do
    names = ["IMG_10.jpg", "img_9.jpg", "page 2.png", "page 10.png", "Page 1.png", nil]

    assert Enum.sort_by(names, &Stacks.natural_key/1) ==
             [nil, "img_9.jpg", "IMG_10.jpg", "Page 1.png", "page 2.png", "page 10.png"]
  end

  describe "dating files by hand" do
    test "the first file gets the date, the others move with it", ctx do
      a = file!(ctx.owner, ctx.library, "a.jpg", ~N[2026-11-11 09:00:00])
      b = file!(ctx.owner, ctx.library, "b.jpg", ~N[2026-11-11 09:01:30])
      # A known offset (UTC+2): its local time moves, its offset stays.
      c =
        file!(ctx.owner, ctx.library, "c.jpg", nil, %{
          taken_at: ~U[2026-11-11 07:05:00Z],
          taken_on: ~D[2026-11-11],
          taken_at_offset: 7200,
          taken_at_source: "exif"
        })

      assert {:ok, uuids} =
               ManualDate.set([a.uuid, b.uuid, c.uuid], ~N[1985-03-12 10:00:00], scope(ctx.owner))

      assert length(uuids) == 3
      assert_receive {:phoenix_kit_files_changed, _}

      a = reload(a)
      assert a.taken_at == ~U[1985-03-12 10:00:00Z]
      assert a.taken_on == ~D[1985-03-12]
      assert a.taken_at_source == "manual"

      assert reload(b).taken_at == ~U[1985-03-12 10:01:30Z]

      # 09:05 local (07:05Z + 2h) moved by the same amount is 10:05 local, 08:05Z.
      c = reload(c)
      assert c.taken_at == ~U[1985-03-12 08:05:00Z]
      assert c.taken_at_offset == 7200
      assert ManualDate.local(c) == ~N[1985-03-12 10:05:00]
    end

    test "a date with no time keeps the first file's time of day, across a year boundary", ctx do
      a = file!(ctx.owner, ctx.library, "a.jpg", ~N[2026-12-31 23:30:00])
      b = file!(ctx.owner, ctx.library, "b.jpg", ~N[2027-01-01 00:10:00])

      {:ok, _} = ManualDate.set([a.uuid, b.uuid], ~D[1999-03-01], scope(ctx.owner))

      assert reload(a).taken_at == ~U[1999-03-01 23:30:00Z]
      # 40 minutes later, which is past midnight: the next day.
      assert reload(b).taken_at == ~U[1999-03-02 00:10:00Z]
      assert reload(b).taken_on == ~D[1999-03-02]
    end

    test "a file with no date yet counts from its upload time", ctx do
      a = file!(ctx.owner, ctx.library, "a.jpg")
      {:ok, _} = ManualDate.set([a.uuid], ~N[2001-05-05 05:05:05], scope(ctx.owner))
      assert reload(a).taken_at == ~U[2001-05-05 05:05:05Z]
    end

    test "an impossible date changes nothing; nor does someone who may not", ctx do
      a = file!(ctx.owner, ctx.library, "a.jpg", ~N[2026-11-11 09:00:00])
      b = file!(ctx.owner, ctx.library, "b.jpg", ~N[2026-11-11 10:00:00])

      assert {:error, :implausible_date} =
               ManualDate.set([a.uuid, b.uuid], ~N[1800-01-01 00:00:00], scope(ctx.owner))

      # The first file would be fine; the second would land in the future.
      tomorrow = NaiveDateTime.add(NaiveDateTime.utc_now(), 86_400 + 600)

      assert {:error, :implausible_date} =
               ManualDate.set(
                 [a.uuid, b.uuid],
                 NaiveDateTime.add(tomorrow, -3600),
                 scope(ctx.owner)
               )

      assert {:error, :forbidden} =
               ManualDate.set([a.uuid], ~N[2000-01-01 00:00:00], scope(user!(nil)))

      assert {:error, :not_found} =
               ManualDate.set([a.uuid, Ecto.UUID.generate()], ~D[2000-01-01], scope(ctx.owner))

      assert reload(a).taken_at_source == "exif"
      refute_receive {:phoenix_kit_files_changed, _}
    end

    test "the way back: the name's date at once, only for files dated by hand", ctx do
      named = file!(ctx.owner, ctx.library, "IMG_20180701_120000.jpg", ~N[2018-07-01 12:00:00])
      other = file!(ctx.owner, ctx.library, "other.jpg", ~N[2020-01-01 00:00:00])

      {:ok, _} = ManualDate.set([named.uuid], ~N[1985-03-12 10:00:00], scope(ctx.owner))
      assert_receive {:phoenix_kit_files_changed, _}

      assert {:ok, [uuid]} = ManualDate.reset([named.uuid, other.uuid], scope(ctx.owner))
      assert uuid == named.uuid
      assert_receive {:phoenix_kit_files_changed, [_]}

      named = reload(named)
      assert named.taken_at == ~U[2018-07-01 12:00:00Z]
      assert named.taken_at_source == "filename"
      assert reload(other).taken_at_source == "exif"

      assert {:error, :forbidden} = ManualDate.reset([named.uuid], scope(user!(nil)))
    end
  end
end
