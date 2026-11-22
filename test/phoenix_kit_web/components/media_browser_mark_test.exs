defmodule PhoenixKitWeb.Components.MediaBrowserMarkTest do
  @moduledoc """
  The `:mark` attr (nil = off) is a host-defined on/off mark on files: a SET
  of file uuids, on every file type, with the host's own icon and wording.
  The browser draws a toggle on every file tile (grid, stacks), a column in
  the list, a kebab item, and relays a click to the host as
  `{MediaBrowser, id, {:set_mark, file_uuid, boolean}}`. It persists nothing.

  Everything here runs without a database: the views are function components
  rendered with plain maps, and the event is driven on a plain socket (event
  params are not UUIDs, so the library gate in front of the handler never
  reaches the repo — the same trick `media_browser_featured_test.exs` uses).
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  import PhoenixKitWeb.MediaCanvasViewerFixtures,
    only: [file_uuid: 0, render_assigns: 1, render_html: 1]

  alias PhoenixKitWeb.Components.MediaBrowser
  alias PhoenixKitWeb.Components.MediaBrowser.{GridView, Helpers, ListView, StacksView}
  alias PhoenixKitWeb.Components.MediaCanvasViewer

  # ---------------------------------------------------------------------------
  # Fixtures — plain maps, the shape `uploaded_files` rows have
  # ---------------------------------------------------------------------------

  defp file(uuid, attrs \\ []) do
    Map.merge(
      %{
        file_uuid: uuid,
        filename: "#{uuid}.jpg",
        file_type: "image",
        mime_type: "image/jpeg",
        size: 1024,
        urls: %{},
        status: "active",
        folder_path: nil,
        inserted_at: ~N[2026-11-01 10:00:00],
        metadata: %{}
      },
      Map.new(attrs)
    )
  end

  defp pdf(uuid), do: file(uuid, file_type: "document", mime_type: "application/pdf")
  defp video(uuid), do: file(uuid, file_type: "video", mime_type: "video/mp4")

  defp folder(uuid) do
    %{
      uuid: uuid,
      name: "Folder #{uuid}",
      color: nil,
      description: nil,
      parent_uuid: nil,
      inserted_at: ~N[2026-11-01 10:00:00]
    }
  end

  defp mark(uuids, extra \\ []),
    do:
      %{uuids: uuids, icon: "hero-eye", on_label: nil, off_label: nil, unmark_label: nil}
      |> Map.merge(Map.new(extra))

  # What the browser hands each view: normalised once by `update/2`.
  defp normalized(m), do: Helpers.normalize_mark(m)

  defp view_assigns(overrides) do
    Map.merge(
      %{
        allow_move: false,
        current_folder: nil,
        drag: false,
        editing_folder_description: nil,
        expanded_stacks: [],
        featured: nil,
        file_view: "folder",
        filter_trash: false,
        folder_actions: true,
        folder_description_text: "",
        folders: [],
        id: "mb",
        just_opened_stack: nil,
        mark: nil,
        myself: "mb",
        pick_mode: :multiple,
        picked: [],
        picker: false,
        readonly: false,
        removal_guarded: false,
        renaming_folder: nil,
        renaming_source: nil,
        renaming_text: "",
        scope: nil,
        scope_folder_id: nil,
        select_mode: false,
        selected_files: MapSet.new(),
        selected_folders: MapSet.new(),
        stack_files: %{},
        stack_previews: %{},
        subtree_listing: false,
        uploaded_files: []
      },
      Map.new(overrides)
    )
  end

  defp grid(overrides),
    do: render_component(&GridView.grid_view/1, view_assigns(overrides)) |> doc()

  defp stacks(overrides),
    do: render_component(&StacksView.stacks_view/1, view_assigns(overrides)) |> doc()

  defp list(overrides),
    do: render_component(&ListView.list_view/1, view_assigns(overrides)) |> doc()

  defp doc(html), do: Floki.parse_fragment!(html)

  defp find(doc, selector), do: Floki.find(doc, selector)

  defp attr(nodes, name), do: nodes |> Floki.attribute(name)

  # The round control on a tile: the toggle (button) or the passive badge (div).
  defp toggles(doc), do: find(doc, ~s(button[data-role^="mark-"]))
  defp badges(doc), do: find(doc, ~s(div[data-role="mark-on"]))
  defp marks_for(doc, uuid), do: find(doc, ~s([data-mark-file="#{uuid}"]))

  # Every view that draws file tiles/rows, each fed the same files.
  defp each_view(overrides, fun) do
    for {name, render} <- [grid: &grid/1, stacks: &stacks/1, list: &list/1] do
      fun.(name, render.(overrides))
    end
  end

  # ---------------------------------------------------------------------------
  # Pure helpers
  # ---------------------------------------------------------------------------

  describe "normalize_mark/1" do
    test "nil stays nil — the feature is off" do
      assert Helpers.normalize_mark(nil) == nil
    end

    test "a list and a MapSet both become a MapSet" do
      assert %{uuids: %MapSet{} = a} = Helpers.normalize_mark(mark(["a", "b"]))
      assert %{uuids: %MapSet{} = b} = Helpers.normalize_mark(mark(MapSet.new(["a", "b"])))
      assert a == b
      assert MapSet.member?(a, "a")
    end

    test "false is as absent as nil — `mark={cond && %{...}}` turns the feature off" do
      assert Helpers.normalize_mark(false) == nil
    end

    test "defaults: eye icon, no labels (the gettext fallbacks apply at render)" do
      assert %{
               icon: "hero-eye",
               on_label: nil,
               off_label: nil,
               unmark_label: nil,
               uuids: uuids
             } = Helpers.normalize_mark(%{})

      assert MapSet.size(uuids) == 0
    end

    test "a map with only `uuids` is a whole mark, as the component treats its other options" do
      assert %{uuids: uuids, icon: "hero-eye"} = Helpers.normalize_mark(%{uuids: ["a"]})
      assert MapSet.member?(uuids, "a")
    end

    test "something that is neither nil, false nor a map is refused, naming the attr" do
      for bad <- [["a"], "a", MapSet.new(["a"]), true] do
        assert_raise ArgumentError, ~r/:mark/, fn -> Helpers.normalize_mark(bad) end
      end
    end

    test "keeps the host's icon and labels" do
      assert %{
               icon: "hero-check-badge",
               on_label: "Approved",
               off_label: "Approve",
               unmark_label: "Withdraw"
             } =
               Helpers.normalize_mark(%{
                 uuids: [],
                 icon: "hero-check-badge",
                 on_label: "Approved",
                 off_label: "Approve",
                 unmark_label: "Withdraw"
               })
    end

    test "an empty label is no label: the gettext fallback applies" do
      assert %{on_label: nil, off_label: nil, unmark_label: nil} =
               Helpers.normalize_mark(%{on_label: "", off_label: "", unmark_label: ""})
    end

    test "is idempotent" do
      once = Helpers.normalize_mark(mark(["a"], on_label: "Yes"))
      assert Helpers.normalize_mark(once) == once
    end
  end

  describe "marked?/2" do
    test "nil, MapSet and list" do
      refute Helpers.marked?(nil, "a")
      assert Helpers.marked?(normalized(mark(["a"])), "a")
      refute Helpers.marked?(normalized(mark(["a"])), "b")
      assert Helpers.marked?(%{uuids: ["a"]}, "a")
    end
  end

  # The naming rule (see the moduledoc's `:mark`): a control is named for what
  # a click DOES — `off_label` marks, `unmark_label` removes — and carries no
  # `aria-pressed`, so the state is never stated twice. `on_label` names the
  # STATE and is only drawn where there is no control: the passive badge.
  describe "mark_label/2 and mark_state_label/1" do
    test "the control is named for its action, the host's wording first" do
      m =
        normalized(mark([], off_label: "Approve", unmark_label: "Withdraw", on_label: "Approved"))

      assert Helpers.mark_label(m, false) == "Approve"
      assert Helpers.mark_label(m, true) == "Withdraw"
    end

    test "without the host's wording: Mark / Remove mark" do
      m = normalized(mark([], on_label: "Approved"))
      assert Helpers.mark_label(m, false) == "Mark"
      assert Helpers.mark_label(m, true) == "Remove mark"
    end

    test "the state is on_label, Marked without it" do
      assert Helpers.mark_state_label(normalized(mark([], on_label: "Approved"))) == "Approved"
      assert Helpers.mark_state_label(normalized(mark([]))) == "Marked"
    end
  end

  # ---------------------------------------------------------------------------
  # Off by default
  # ---------------------------------------------------------------------------

  describe "mark: nil (default)" do
    test "no view renders any mark control, column or kebab item" do
      files = [file("a"), pdf("b"), video("c")]

      each_view(%{uploaded_files: files, folders: [folder("f")]}, fn name, doc ->
        assert find(doc, ~s([data-role^="mark-"])) == [], "#{name}: a mark control rendered"
        assert find(doc, "[data-mark-file]") == [], "#{name}: data-mark-file rendered"
        assert find(doc, ~s([phx-click="toggle_mark"])) == [], "#{name}: kebab item rendered"
        assert find(doc, "th[data-mark-column]") == [], "#{name}: column rendered"
      end)
    end

    test "the list has exactly the columns it always had" do
      with_mark =
        list(%{uploaded_files: [file("a")], mark: normalized(mark([]))}) |> find("thead th")

      without = list(%{uploaded_files: [file("a")]}) |> find("thead th")

      assert length(with_mark) == length(without) + 1
    end
  end

  # ---------------------------------------------------------------------------
  # On — roles, labels, icon, file types, folders
  # ---------------------------------------------------------------------------

  describe "mark: a map" do
    test "marked and unmarked files carry the right role and an action name (grid, stacks, list)" do
      m =
        normalized(
          mark(["a"], on_label: "Approved", off_label: "Approve", unmark_label: "Withdraw")
        )

      each_view(%{uploaded_files: [file("a"), file("b")], mark: m}, fn name, doc ->
        on_btn = doc |> marks_for("a") |> Enum.filter(&match?({"button", _, _}, &1))
        off_btn = doc |> marks_for("b") |> Enum.filter(&match?({"button", _, _}, &1))

        assert [_] = on_btn, "#{name}"
        assert [_] = off_btn, "#{name}"

        assert attr(on_btn, "data-role") == ["mark-on"], "#{name}"
        assert attr(on_btn, "title") == ["Withdraw"], "#{name}"
        assert attr(on_btn, "aria-label") == ["Withdraw"], "#{name}"
        assert attr(on_btn, "phx-click") == ["toggle_mark"], "#{name}"
        assert attr(on_btn, "phx-value-file-uuid") == ["a"], "#{name}"

        assert attr(off_btn, "data-role") == ["mark-off"], "#{name}"
        assert attr(off_btn, "title") == ["Approve"], "#{name}"
        assert attr(off_btn, "aria-label") == ["Approve"], "#{name}"
        assert attr(off_btn, "phx-value-file-uuid") == ["b"], "#{name}"

        # The name flips with the action, so the state is not stated a second
        # time with aria-pressed.
        assert attr(on_btn, "aria-pressed") == [], "#{name}"
        assert attr(off_btn, "aria-pressed") == [], "#{name}"
      end)
    end

    test "the gettext fallbacks name the control when the host gave no wording" do
      each_view(%{uploaded_files: [file("a"), file("b")], mark: normalized(mark(["a"]))}, fn name,
                                                                                             doc ->
        assert doc
               |> toggles()
               |> Enum.map(&Floki.attribute(&1, "title"))
               |> List.flatten()
               |> Enum.sort() ==
                 ["Mark", "Remove mark"],
               "#{name}"
      end)
    end

    test "the host's icon is drawn, in both states" do
      m = normalized(mark(["a"], icon: "hero-flag"))

      each_view(%{uploaded_files: [file("a"), file("b")], mark: m}, fn name, doc ->
        for uuid <- ["a", "b"] do
          button = doc |> marks_for(uuid) |> Enum.filter(&match?({"button", _, _}, &1))
          assert find(button, ".hero-flag") != [], "#{name}: #{uuid} lacks the host's icon"
        end
      end)
    end

    test "the default icon is the eye" do
      each_view(%{uploaded_files: [file("a")], mark: normalized(%{uuids: []})}, fn name, doc ->
        assert find(doc, "button[data-mark-file] .hero-eye") != [], "#{name}"
      end)
    end

    test "every file type gets it — images, PDFs, videos, plain documents" do
      files = [
        file("img"),
        pdf("pdf"),
        video("vid"),
        file("doc", file_type: "document", mime_type: "text/plain")
      ]

      each_view(%{uploaded_files: files, mark: normalized(mark(["pdf"]))}, fn name, doc ->
        for uuid <- ["img", "pdf", "vid", "doc"] do
          assert [_ | _] = marks_for(doc, uuid), "#{name}: no mark control on #{uuid}"
        end

        assert doc |> marks_for("pdf") |> attr("data-role") |> Enum.member?("mark-on"), "#{name}"
      end)
    end

    test "folders never get the mark" do
      each_view(
        %{
          uploaded_files: [file("a")],
          folders: [folder("f1"), folder("f2")],
          mark: normalized(mark(["f1"]))
        },
        fn name, doc ->
          assert marks_for(doc, "f1") == [], "#{name}"
          assert marks_for(doc, "f2") == [], "#{name}"
          assert doc |> toggles() |> length() == 1, "#{name}: one toggle for the one file"
        end
      )
    end

    test "a list and a MapSet are the same to the views" do
      for uuids <- [["a"], MapSet.new(["a"])] do
        each_view(
          %{uploaded_files: [file("a"), file("b")], mark: normalized(mark(uuids))},
          fn name, doc ->
            assert doc |> marks_for("a") |> attr("data-role") |> Enum.member?("mark-on"),
                   "#{name}"

            assert doc |> marks_for("b") |> attr("data-role") |> Enum.member?("mark-off"),
                   "#{name}"
          end
        )
      end
    end

    test "the toggle is a sibling of the click_file target, so a click on it never opens the viewer (grid, stacks)" do
      for doc <- [
            grid(%{uploaded_files: [file("a")], mark: normalized(mark([]))}),
            stacks(%{uploaded_files: [file("a")], mark: normalized(mark([]))})
          ] do
        assert [_] = toggles(doc)
        assert find(doc, ~s([phx-click="click_file"] [data-role^="mark-"])) == []
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Placement — the corner is shared, so offsets are asserted
  # ---------------------------------------------------------------------------

  describe "placement of the tile's toggle" do
    defp classes(nodes), do: nodes |> attr("class") |> hd() |> String.split()

    test "alone, it takes the corner the star would; after the star when both are on" do
      m = normalized(mark([]))

      alone = grid(%{uploaded_files: [file("a")], mark: m})
      assert "left-1.5" in classes(find(alone, ~s(button[data-mark-file="a"])))

      with_star =
        grid(%{uploaded_files: [file("a")], mark: m, featured: %{uuid: nil, label: nil}})

      assert "left-1.5" in classes(find(with_star, ~s(button[data-role="featured-toggle"])))
      assert "left-8" in classes(find(with_star, ~s(button[data-mark-file="a"])))
    end

    test "on a PDF (no star there) it keeps the corner, and the PDF badge steps below it" do
      doc =
        grid(%{
          uploaded_files: [pdf("p")],
          mark: normalized(mark([])),
          featured: %{uuid: nil, label: nil}
        })

      assert "left-1.5" in classes(find(doc, ~s(button[data-mark-file="p"])))
      assert "top-9" in classes(find(doc, ~s|div[class*="bg-error/80"]|))
      refute "top-2" in classes(find(doc, ~s|div[class*="bg-error/80"]|))
    end

    test "without mark the PDF and video badges stay where they were" do
      doc = grid(%{uploaded_files: [pdf("p"), video("v")]})
      assert length(find(doc, ".top-2.left-2")) == 2
      assert find(doc, ".top-9") == []
    end

    test "the stacks card moves its video/PDF badges the same way" do
      doc = stacks(%{uploaded_files: [video("v")], mark: normalized(mark([]))})
      assert "top-9" in classes(find(doc, ~s|div[class*="bg-black/60"][class*="p-1.5"]|))
    end

    test "the toggle matches the star's size" do
      doc = grid(%{uploaded_files: [file("a")], mark: normalized(mark([]))})
      assert ~w(w-5 h-5 rounded-full) -- classes(find(doc, ~s(button[data-mark-file="a"]))) == []
    end
  end

  # ---------------------------------------------------------------------------
  # No toggle: select mode, trash, readonly, picker — a plain badge on marked files
  # ---------------------------------------------------------------------------

  describe "no toggle in select mode, the trash, readonly, or a picker" do
    defp passive_only(doc, name) do
      assert toggles(doc) == [], "#{name}: a toggle rendered"
      assert find(doc, ~s([phx-click="toggle_mark"])) == [], "#{name}: a kebab item rendered"
      assert [badge] = badges(doc), "#{name}: expected exactly one badge, for the marked file"
      assert Floki.attribute(badge, "data-mark-file") == ["a"], name
      # unmarked files show nothing at all
      assert marks_for(doc, "b") == [], "#{name}"
      badge
    end

    for {label, overrides} <- [
          select_mode: %{select_mode: true},
          trash: %{filter_trash: true},
          readonly: %{readonly: true}
        ] do
      @overrides overrides
      @label label

      test "#{label}: grid, stacks and list show the badge only on the marked file" do
        each_view(
          Map.merge(
            %{
              uploaded_files: [file("a"), file("b")],
              mark: normalized(mark(["a"], on_label: "Approved"))
            },
            @overrides
          ),
          fn name, doc ->
            badge = passive_only(doc, "#{@label}/#{name}")
            assert Floki.attribute(badge, "class") |> hd() =~ "pointer-events-none"
            # the tooltip lives on an inner element that takes pointer events back
            assert [tip] = Floki.find(badge, "[title]")
            assert Floki.attribute(tip, "title") == ["Approved"]
            assert Floki.attribute(tip, "class") |> hd() =~ "pointer-events-auto"
            # a marked file has an accessible name even with no control
            assert Floki.attribute(badge, "role") == ["img"]
            assert Floki.attribute(badge, "aria-label") == ["Approved"]
          end
        )
      end
    end

    test "the passive badge's name falls back to Marked" do
      doc = grid(%{select_mode: true, uploaded_files: [file("a")], mark: normalized(mark(["a"]))})
      assert [badge] = badges(doc)
      assert Floki.attribute(badge, "aria-label") == ["Marked"]
    end

    test "a picker: grid shows the badge only, steps right of the eye, and no kebab item" do
      doc =
        grid(%{
          picker: true,
          uploaded_files: [file("a"), file("b")],
          mark: normalized(mark(["a"]))
        })

      badge = passive_only(doc, "picker/grid")
      assert "left-8" in classes([badge])
      refute "left-1.5" in classes([badge])
    end

    test "select mode: the badge steps right of the checkbox" do
      doc =
        grid(%{select_mode: true, uploaded_files: [file("a")], mark: normalized(mark(["a"]))})

      assert [badge] = badges(doc)
      assert "left-7" in classes([badge])
    end

    test "with the star badge on the same tile the mark badge steps right of both" do
      for {overrides, star_left, mark_left} <- [
            {%{select_mode: true}, "left-7", "left-14"},
            {%{filter_trash: true}, "left-1.5", "left-8"},
            {%{picker: true}, "left-8", "left-14"}
          ] do
        doc =
          grid(
            Map.merge(
              %{
                uploaded_files: [file("a")],
                mark: normalized(mark(["a"])),
                featured: %{uuid: "a", label: nil}
              },
              overrides
            )
          )

        assert star_left in classes(find(doc, ~s(div[data-role="featured-badge"]))),
               inspect(overrides)

        assert mark_left in classes(badges(doc)), inspect(overrides)
      end
    end

    test "a marked file in the list still shows the solid badge when readonly, in its own column" do
      doc = list(%{readonly: true, uploaded_files: [file("a")], mark: normalized(mark(["a"]))})
      assert [_] = badges(doc)
      assert find(doc, "td [data-role=\"mark-on\"]") != []
    end
  end

  # ---------------------------------------------------------------------------
  # Kebab and list column
  # ---------------------------------------------------------------------------

  describe "kebab item" do
    defp kebab_items(doc) do
      doc
      |> find(~s|[phx-click="toggle_mark"]:not([data-mark-file])|)
      |> Enum.sort_by(&(&1 |> List.wrap() |> Floki.attribute("phx-value-file-uuid") |> hd()))
    end

    test "every file's kebab gains one item named for its action (grid, stacks, list)" do
      m =
        normalized(
          mark(["a"], on_label: "Approved", off_label: "Approve", unmark_label: "Withdraw")
        )

      each_view(%{uploaded_files: [file("a"), pdf("b")], mark: m}, fn name, doc ->
        items = kebab_items(doc)

        assert length(items) == 2, "#{name}: one kebab item per file"

        # The marked file's item removes the mark, and says so — not "Approved".
        assert Enum.map(items, &(&1 |> List.wrap() |> Floki.text() |> String.trim())) ==
                 ["Withdraw", "Approve"],
               "#{name}"

        assert find(items, ".hero-eye") != [], "#{name}"
      end)
    end

    test "the item is not a toggle button: no aria-pressed, so the name carries the action" do
      each_view(%{uploaded_files: [file("a")], mark: normalized(mark(["a"]))}, fn name, doc ->
        assert [item] = kebab_items(doc)
        assert Floki.attribute(item, "aria-pressed") == [], "#{name}"
      end)
    end

    test "clicking it (its own event and params, as rendered) marks, then unmarks" do
      each_view(%{uploaded_files: [file("a"), file("b")], mark: normalized(mark(["a"]))}, fn name,
                                                                                             doc ->
        for {item, uuid, on?} <- Enum.zip([kebab_items(doc), ["a", "b"], [false, true]]) do
          assert [event] = Floki.attribute(item, "phx-click"), "#{name}"
          assert [params_uuid] = Floki.attribute(item, "phx-value-file-uuid"), "#{name}"
          assert params_uuid == uuid

          socket =
            socket_with(%{
              uploaded_files: [file("a"), file("b")],
              mark: normalized(mark(["a"]))
            })

          {:noreply, socket} =
            MediaBrowser.handle_event(event, %{"file-uuid" => params_uuid}, socket)

          assert_received {MediaBrowser, "mb", {:set_mark, ^uuid, ^on?}}
          assert MapSet.member?(socket.assigns.mark.uuids, uuid) == on?, "#{name}"
        end
      end)
    end

    test "readonly and the trash draw no item" do
      for overrides <- [%{readonly: true}, %{filter_trash: true}] do
        each_view(
          Map.merge(%{uploaded_files: [file("a")], mark: normalized(mark(["a"]))}, overrides),
          fn name, doc ->
            assert kebab_items(doc) == [], "#{name} #{inspect(overrides)}"
          end
        )
      end
    end

    test "a picker (always the grid) draws no item" do
      doc = grid(%{picker: true, uploaded_files: [file("a")], mark: normalized(mark(["a"]))})
      assert kebab_items(doc) == []
    end
  end

  describe "list column" do
    test "a narrow header cell with an sr-only label, and a toggle cell per file; folders get an empty cell" do
      doc =
        list(%{
          uploaded_files: [file("a")],
          folders: [folder("f")],
          mark: normalized(mark([], off_label: "Approve"))
        })

      assert [th] = find(doc, "th[data-mark-column]")
      assert [label] = Floki.find(th, ".sr-only")
      assert Floki.text(label) =~ "Approve"

      column_count = doc |> find("thead th") |> length()

      for row <- find(doc, "tbody tr") do
        cells = Floki.find(row, "td")

        spans =
          cells
          |> Enum.map(
            &(Floki.attribute(&1, "colspan")
              |> List.first()
              |> then(fn
                nil -> 1
                n -> String.to_integer(n)
              end))
          )
          |> Enum.sum()

        assert spans == column_count, "a row is a different width than the header"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The event — direct handle_event/3 on a plain socket
  # ---------------------------------------------------------------------------

  defp socket_with(assigns) do
    base = %{
      __changed__: %{},
      id: "mb",
      mark: normalized(mark(["m1"])),
      readonly: false,
      picker: false,
      filter_trash: false,
      uploaded_files: [file("m1"), file("u1"), file("t1", status: "trashed")],
      stack_files: %{}
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(base, Map.new(assigns))}
  end

  describe "toggle_mark event" do
    test "marking an unmarked file sends {:set_mark, uuid, true} and flips the local set" do
      {:noreply, socket} =
        MediaBrowser.handle_event("toggle_mark", %{"file-uuid" => "u1"}, socket_with(%{}))

      assert_received {MediaBrowser, "mb", {:set_mark, "u1", true}}
      assert MapSet.member?(socket.assigns.mark.uuids, "u1")
      assert MapSet.member?(socket.assigns.mark.uuids, "m1")
    end

    test "unmarking a marked file sends {:set_mark, uuid, false}" do
      {:noreply, socket} =
        MediaBrowser.handle_event("toggle_mark", %{"file-uuid" => "m1"}, socket_with(%{}))

      assert_received {MediaBrowser, "mb", {:set_mark, "m1", false}}
      refute MapSet.member?(socket.assigns.mark.uuids, "m1")
    end

    test "the icon and wording survive the flip" do
      m = normalized(mark(["m1"], icon: "hero-flag", on_label: "Yes", off_label: "No"))

      {:noreply, socket} =
        MediaBrowser.handle_event("toggle_mark", %{"file-uuid" => "u1"}, socket_with(%{mark: m}))

      assert %{icon: "hero-flag", on_label: "Yes", off_label: "No"} = socket.assigns.mark
    end

    test "a file inside an expanded stack is a file the browser shows" do
      socket = socket_with(%{uploaded_files: [], stack_files: %{"folder" => [file("s1")]}})

      {:noreply, socket} =
        MediaBrowser.handle_event("toggle_mark", %{"file-uuid" => "s1"}, socket)

      assert_received {MediaBrowser, "mb", {:set_mark, "s1", true}}
      assert MapSet.member?(socket.assigns.mark.uuids, "s1")
    end

    test "the file open in the viewer counts even when the page does not list it" do
      socket = socket_with(%{uploaded_files: [], viewer_file: file("v1")})
      {:noreply, _} = MediaBrowser.handle_event("toggle_mark", %{"file-uuid" => "v1"}, socket)

      assert_received {MediaBrowser, "mb", {:set_mark, "v1", true}}
    end

    test "own_files_only does not stop it: a host marks other people's files on purpose" do
      socket = socket_with(%{own_files_only: "someone-else"})
      {:noreply, _} = MediaBrowser.handle_event("toggle_mark", %{"file-uuid" => "u1"}, socket)

      assert_received {MediaBrowser, "mb", {:set_mark, "u1", true}}
    end

    test "it is not one of the writes the own-files guard and the readonly list track" do
      refute "toggle_mark" in MediaBrowser.write_events()
    end

    for {label, assigns} <- [
          readonly: %{readonly: true},
          picker: %{picker: true},
          mark_off: %{mark: nil},
          unknown_file: %{uploaded_files: []},
          trashed_file: %{}
        ] do
      @assigns assigns
      @label label

      test "refused, logged and nothing sent: #{label}" do
        uuid = if @label == :trashed_file, do: "t1", else: "u1"
        socket = socket_with(@assigns)

        log =
          capture_log(fn ->
            assert {:noreply, ^socket} =
                     MediaBrowser.handle_event("toggle_mark", %{"file-uuid" => uuid}, socket)
          end)

        refute_received {MediaBrowser, _, _}
        assert log =~ "toggle_mark"
      end
    end

    test "a params map without a file is refused too" do
      socket = socket_with(%{})

      capture_log(fn ->
        assert {:noreply, ^socket} = MediaBrowser.handle_event("toggle_mark", %{}, socket)
      end)

      refute_received {MediaBrowser, _, _}
    end

    test "a picker lists it with the other file writes it refuses" do
      assert "toggle_mark" in MediaBrowser.picker_file_write_events()
    end
  end

  # ---------------------------------------------------------------------------
  # A later `mark` assign from the host replaces the local state
  # ---------------------------------------------------------------------------

  describe "the host's `mark` assign" do
    # A mounted browser, as `update/2` meets it on a later assign (`send_update`
    # or a parent render): `update/2` itself runs without a database here.
    defp mounted(assigns) do
      %Phoenix.LiveView.Socket{
        assigns:
          Map.merge(
            %{
              __changed__: %{},
              id: "mb",
              uploaded_files: [file("m1"), file("u1")],
              library_uuid: nil,
              per_page: 24,
              readonly: false
            },
            Map.new(assigns)
          )
      }
    end

    test "turns the feature on and is normalised on the way in" do
      {:ok, socket} = MediaBrowser.update(%{id: "mb", mark: %{uuids: ["m1"]}}, mounted(%{}))

      assert %{uuids: %MapSet{} = uuids, icon: "hero-eye"} = socket.assigns.mark
      assert MapSet.member?(uuids, "m1")
    end

    test "absent, the feature stays off" do
      {:ok, socket} = MediaBrowser.update(%{id: "mb"}, mounted(%{}))
      assert socket.assigns.mark == nil
    end

    test "a later assign replaces the optimistic state the click left" do
      {:ok, socket} = MediaBrowser.update(%{id: "mb", mark: %{uuids: ["m1"]}}, mounted(%{}))

      {:noreply, socket} =
        MediaBrowser.handle_event("toggle_mark", %{"file-uuid" => "u1"}, socket)

      assert MapSet.member?(socket.assigns.mark.uuids, "u1")
      assert_received {MediaBrowser, "mb", {:set_mark, "u1", true}}

      # The host's write was rejected: it sends the set as it stands.
      {:ok, socket} = MediaBrowser.update(%{id: "mb", mark: %{uuids: ["m1"]}}, socket)

      refute MapSet.member?(socket.assigns.mark.uuids, "u1")
      assert MapSet.member?(socket.assigns.mark.uuids, "m1")
    end

    test "an assign without `mark` leaves the local state alone" do
      {:ok, socket} = MediaBrowser.update(%{id: "mb", mark: %{uuids: []}}, mounted(%{}))

      {:noreply, socket} =
        MediaBrowser.handle_event("toggle_mark", %{"file-uuid" => "u1"}, socket)

      {:ok, socket} = MediaBrowser.update(%{id: "mb", readonly: false}, socket)

      assert MapSet.member?(socket.assigns.mark.uuids, "u1")
    end
  end

  # ---------------------------------------------------------------------------
  # The viewer's sidebar
  # ---------------------------------------------------------------------------

  describe "viewer sidebar button" do
    # The sidebar's own assigns (what `update/2` seeds from the database on
    # open), as empty as they start.
    @sidebar_assigns %{
      sidebar_collapsed: false,
      media_tags: [],
      media_meta_own: %{title: "", alt: "", description: ""},
      media_meta_placeholders: %{title: "", alt: "", description: ""},
      media_meta_langs: [],
      media_meta_values: %{},
      media_meta_status_token: 0,
      file_row: nil,
      file_exif: nil,
      file_geo: {nil, nil},
      exif_tags: nil,
      exif_status: nil
    }

    defp sidebar(overrides),
      do: @sidebar_assigns |> Map.merge(overrides) |> render_html() |> doc()

    defp sidebar_buttons(doc), do: find(doc, ~s(button[phx-click="toggle_mark"]))

    test "an unmarked file: an outline button named for the action, nothing pressed" do
      doc = sidebar(%{mark: normalized(mark([], off_label: "Approve"))})

      assert [button] = sidebar_buttons(doc)
      assert Floki.attribute(button, "data-role") == ["mark-off"]

      assert Floki.attribute(button, "data-mark-file") == [
               file_uuid()
             ]

      assert Floki.attribute(button, "phx-target") == ["#mb-test"]
      assert Floki.text(button) =~ "Approve"
      assert Floki.attribute(button, "class") |> hd() =~ "btn-ghost"
      assert Floki.attribute(button, "aria-pressed") == []
    end

    test "a marked file: primary, named for removing the mark, no aria-pressed" do
      uuid = file_uuid()

      doc =
        sidebar(%{
          mark: normalized(mark([uuid], on_label: "Approved", unmark_label: "Withdraw"))
        })

      assert [button] = sidebar_buttons(doc)
      assert Floki.attribute(button, "data-role") == ["mark-on"]
      assert Floki.attribute(button, "class") |> hd() =~ "btn-primary"
      assert Floki.text(button) =~ "Withdraw"
      refute Floki.text(button) =~ "Approved"
      assert Floki.attribute(button, "aria-pressed") == []
    end

    test "the host's icon, and the gettext fallbacks" do
      doc = sidebar(%{mark: normalized(mark([], icon: "hero-flag"))})
      assert [button] = sidebar_buttons(doc)
      assert find([button], ".hero-flag") != []
      assert Floki.text(button) =~ "Mark"
    end

    test "any file type — a PDF too" do
      pdf =
        Map.merge(render_assigns(%{}).file, %{
          file_type: "document",
          mime_type: "application/pdf"
        })

      assert [_] = sidebar(%{file: pdf, mark: normalized(mark([]))}) |> sidebar_buttons()
    end

    test "never on a trashed file" do
      file =
        render_assigns(%{}).file
        |> Map.put(:status, "trashed")

      assert sidebar(%{file: file, mark: normalized(mark([]))}) |> sidebar_buttons() == []
    end

    test "off with mark nil" do
      assert sidebar(%{mark: nil}) |> sidebar_buttons() == []
    end

    test "update/2 normalises what a direct user hands in: a raw uuid list, false" do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      base = %{id: "v", file: nil, board: nil}

      {:ok, socket_raw} =
        MediaCanvasViewer.update(
          Map.put(base, :mark, %{uuids: ["a"]}),
          socket
        )

      assert %{uuids: %MapSet{}, icon: "hero-eye"} = socket_raw.assigns.mark

      {:ok, socket_false} =
        MediaCanvasViewer.update(Map.put(base, :mark, false), socket)

      assert socket_false.assigns.mark == nil
    end
  end

  describe "viewer_mark/3 — what the browser hands its viewer" do
    test "the mark, as it is" do
      m = normalized(mark(["a"]))
      assert Helpers.viewer_mark(m, false, false) == m
    end

    test "nothing when readonly or a picker, whatever the mark" do
      m = normalized(mark(["a"]))
      assert Helpers.viewer_mark(m, true, false) == nil
      assert Helpers.viewer_mark(m, false, true) == nil
      assert Helpers.viewer_mark(m, true, true) == nil
    end

    test "nothing when the host never opted in" do
      assert Helpers.viewer_mark(nil, false, false) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # A host that forgets to match the message
  # ---------------------------------------------------------------------------

  describe "handle_parent_info/2" do
    test "a {:set_mark, _, _} the host did not handle is said in the log, not dropped silently" do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

      log =
        capture_log(fn ->
          assert {:noreply, ^socket} =
                   MediaBrowser.handle_parent_info(
                     {MediaBrowser, "mb", {:set_mark, "u1", true}},
                     socket
                   )
        end)

      assert log =~ "[warning]"
      assert log =~ "id=mb"
      assert log =~ "set_mark"
    end
  end
end
