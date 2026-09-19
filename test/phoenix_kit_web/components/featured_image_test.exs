defmodule PhoenixKitWeb.Components.FeaturedImageTest do
  @moduledoc """
  `FeaturedImage` renders one entity's image pointer, owns the picker protocol
  and relays every choice to the host as
  `{FeaturedImage, id, {:set_featured, uuid | nil}}` — it never writes anything
  itself.

  Three layers, mirroring `media_browser_featured_test.exs`:

    * `render_component/2` for what the markup looks like in each state;
    * the `update/2` / `handle_event/3` callbacks called directly on a socket
      built by the component's own general `update/2`, asserting on the
      messages that land in the test process's mailbox;
    * `live_isolated/3` with a tiny `Host` for the parts that need a running
      LiveView: real clicks on `data-role`s, the lazy-scope handshake, a host
      `<form phx-change>`, and the full open → select → host assign → new
      thumbnail circle.

  ExUnit cannot see inside `<.portal>` (its content sits in a `<template>`), so
  the modal → `notify` → `update/2` seam is driven with `send_update` and the
  modal's presence is asserted on the portal element itself.
  """

  use PhoenixKitWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.FeaturedImage

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp create_folder! do
    {:ok, folder} = Storage.create_folder(%{name: "folder_#{System.unique_integer([:positive])}"})
    folder
  end

  defp create_file!(folder_uuid, overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          original_file_name: "file_#{n}.jpg",
          file_name: "file_#{n}.jpg",
          mime_type: "image/jpeg",
          file_type: "image",
          ext: "jpg",
          file_checksum: "sha256:test-#{n}",
          user_file_checksum: "user-sha256:test-#{n}",
          size: 1024,
          status: "active",
          folder_uuid: folder_uuid,
          user_uuid: ensure_user!()
        },
        overrides
      )

    {:ok, file} = Repo.insert(struct!(StorageFile, attrs))
    file
  end

  defp set_status!(file, status) do
    {:ok, file} = file |> Ecto.Changeset.change(%{status: status}) |> Repo.update()
    file
  end

  defp ensure_user! do
    case Process.get(:test_owner_user_uuid) do
      nil ->
        n = System.unique_integer([:positive])

        {:ok, user} =
          Auth.register_user(%{
            email: "featured-image-test-#{n}@example.com",
            password: "ValidPassword123!"
          })

        Process.put(:test_owner_user_uuid, user.uuid)
        user.uuid

      uuid ->
        uuid
    end
  end

  defp folder_and_file(overrides \\ %{}) do
    folder = create_folder!()
    {folder, create_file!(folder.uuid, overrides)}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp render_fi(attrs) do
    [id: "fi"]
    |> Keyword.merge(attrs)
    |> then(&render_component(FeaturedImage, &1))
    |> LazyHTML.from_fragment()
  end

  defp role(id \\ "fi", name), do: ~s([data-role="#{name}-#{id}"])

  defp found?(doc, selector), do: not Enum.empty?(LazyHTML.query(doc, selector))

  defp attr(doc, selector, name), do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  defp state(doc), do: doc |> attr("#fi", "data-state") |> hd()

  # A socket that went through the component's own general `update/2`, so every
  # default is in place exactly as it is at runtime.
  defp socket_for(attrs) do
    {:ok, socket} =
      FeaturedImage.update(
        Map.merge(%{id: "fi"}, Map.new(attrs)),
        %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      )

    socket
  end

  # Each hop of a component → host → component exchange is a message the
  # LiveView sends itself, so a single `render/1` can return before the last
  # hop has landed. Three round trips cover the longest chain used here.
  defp settle(view), do: Enum.reduce(1..3, nil, fn _, _ -> render(view) end)

  defp mailbox do
    {:messages, messages} = Process.info(self(), :messages)
    messages
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Host — a tiny LiveView owning the component the way a real host would
  # ---------------------------------------------------------------------------

  defmodule Host do
    @moduledoc false
    use Phoenix.LiveView

    alias PhoenixKitWeb.Components.FeaturedImage

    # ConnCase's `using` block (in scope from the enclosing test module)
    # imports `Plug.Conn`, whose `assign/3` would make a bare call ambiguous.
    defp set_assign(socket, key, value), do: Phoenix.Component.assign(socket, key, value)

    def mount(_params, session, socket) do
      {:ok,
       socket
       |> set_assign(:attrs, Map.new(session["attrs"]))
       |> set_assign(:slots, session["slots"] || [])
       |> set_assign(:lazy, session["lazy"])
       |> set_assign(:refuse_writes, session["refuse_writes"] || false)
       |> set_assign(:direct_modal, session["direct_modal"] || false)
       |> set_assign(:test_pid, session["test_pid"])}
    end

    def handle_event("validate", _params, socket) do
      send(socket.assigns.test_pid, :host_form_validate)
      {:noreply, socket}
    end

    def handle_event("preview", params, socket) do
      send(socket.assigns.test_pid, {:preview, params})
      {:noreply, socket}
    end

    # Lets a test change what the host passes to the component, the way a real
    # host re-renders with new assigns.
    def handle_info({:put_attr, key, value}, socket) do
      {:noreply, set_assign(socket, :attrs, Map.put(socket.assigns.attrs, key, value))}
    end

    # The host writes the pointer, then hands the new value back through the
    # attr — the component is controlled and never updates `uuid` itself.
    def handle_info({FeaturedImage, _id, {:set_featured, uuid}}, socket) do
      send(socket.assigns.test_pid, {:set_featured_received, uuid})

      if socket.assigns.refuse_writes do
        {:noreply, socket}
      else
        {:noreply, set_assign(socket, :attrs, Map.put(socket.assigns.attrs, :uuid, uuid))}
      end
    end

    def handle_info({FeaturedImage, _id, :picker_closed}, socket) do
      send(socket.assigns.test_pid, :picker_closed_received)
      {:noreply, socket}
    end

    def handle_info({FeaturedImage, id, :scope_requested}, socket) do
      send(socket.assigns.test_pid, :scope_requested_received)

      case socket.assigns.lazy do
        {:grant, folder_uuid} ->
          socket =
            set_assign(
              socket,
              :attrs,
              Map.put(socket.assigns.attrs, :picker_scope, {:folder, folder_uuid})
            )

          Phoenix.LiveView.send_update(FeaturedImage, id: id, open_picker: true)
          {:noreply, socket}

        :deny ->
          Phoenix.LiveView.send_update(FeaturedImage, id: id, open_picker: false)
          {:noreply, socket}

        {:error, message} ->
          Phoenix.LiveView.send_update(FeaturedImage, id: id, error: message)
          {:noreply, socket}

        # Answers `open_picker: true` without ever putting a folder in the attr.
        :grant_without_folder ->
          Phoenix.LiveView.send_update(FeaturedImage, id: id, open_picker: true)
          {:noreply, socket}

        :silent ->
          {:noreply, socket}
      end
    end

    def render(assigns) do
      ~H"""
      <form id="host-form" phx-change="validate">
        <input type="text" name="host[name]" value="" />
        <.live_component module={FeaturedImage} id="fi" {@attrs}>
          <:empty :if={:empty in @slots}>
            <span data-role="initials">JD</span>
          </:empty>
          <:empty_hint :if={:empty_hint in @slots}>
            <span data-role="upload-first">Upload files first</span>
          </:empty_hint>
        </.live_component>
        <%!-- The REAL modal, beside the component instead of inside its portal
             (ExUnit cannot reach into a <template>), notifying it exactly as the
             component's own template tells it to: the modal → send_update →
             FeaturedImage.update seam. --%>
        <.live_component
          :if={@direct_modal}
          module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
          id="fi-selector-direct"
          show={true}
          mode={:single}
          file_type_filter={:image}
          lock_file_type
          scope_folder_id={elem(@attrs.picker_scope, 1)}
          selected_uuids={[]}
          phoenix_kit_current_user={nil}
          notify={{FeaturedImage, "fi"}}
        />
      </form>
      """
    end
  end

  defp open_host(attrs, opts \\ []) do
    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), Host,
        session: %{
          "attrs" => attrs,
          "slots" => Keyword.get(opts, :slots, []),
          "lazy" => Keyword.get(opts, :lazy),
          "refuse_writes" => Keyword.get(opts, :refuse_writes, false),
          "direct_modal" => Keyword.get(opts, :direct_modal, false),
          "test_pid" => self()
        }
      )

    view
  end

  # ---------------------------------------------------------------------------
  # Render — states
  # ---------------------------------------------------------------------------

  describe "render — empty" do
    test "a choosable empty control is a dashed button that opens the picker" do
      {folder, _file} = folder_and_file()
      doc = render_fi(picker_scope: {:folder, folder.uuid})

      assert state(doc) == "empty"
      assert found?(doc, role("open-picker"))
      assert attr(doc, role("open-picker"), "type") == ["button"]
      assert attr(doc, role("open-picker"), "phx-click") == ["open_picker"]
      assert [target] = attr(doc, role("open-picker"), "phx-target")
      assert target != ""
      refute found?(doc, role("menu"))
      refute found?(doc, role("thumb-img"))
    end

    test "the choose button is named by its text at every size (sr-only at 48px)" do
      for size <- [:sm, :md, :lg] do
        doc = render_fi(picker_scope: :lazy, size: size)

        assert doc |> LazyHTML.query(role("open-picker")) |> LazyHTML.text() =~ "Choose image"
      end

      # the caption alone names it: there is no aria-label to fall back on
      assert attr(render_fi(picker_scope: :lazy), role("open-picker"), "aria-label") == []
    end

    test "picker_scope :lazy is choosable too — the folder does not exist yet" do
      doc = render_fi(picker_scope: :lazy)

      assert found?(doc, role("open-picker"))
    end

    test "picker_scope nil is not choosable: an inert placeholder, no button, no modal" do
      doc = render_fi(picker_scope: nil)

      assert state(doc) == "empty"
      refute found?(doc, role("open-picker"))
      assert found?(doc, role("empty"))
      refute found?(doc, "#fi-portal")
    end

    test "{:folder, nil} is not a scope either — it would open the whole library" do
      doc = render_fi(picker_scope: {:folder, nil})

      refute found?(doc, role("open-picker"))
    end

    test "readonly + empty renders no placeholder and no button" do
      doc = render_fi(picker_scope: :lazy, readonly: true)

      refute found?(doc, role("open-picker"))
      refute found?(doc, role("empty"))
      refute found?(doc, role("menu"))
    end
  end

  describe "render — set" do
    test "a thumbnail plus an always-visible menu trigger next to it, not over it" do
      {folder, file} = folder_and_file()
      doc = render_fi(uuid: file.uuid, picker_scope: {:folder, folder.uuid})

      assert state(doc) == "ok"
      assert [src] = attr(doc, role("thumb-img"), "src")
      assert src =~ "/file/#{file.uuid}/thumbnail/"
      assert attr(doc, role("thumb-img"), "alt") == [file.original_file_name]

      # the menu is a sibling of the thumb frame, and its trigger carries no
      # hover-only opacity — it must be reachable on a touch screen
      assert found?(doc, role("menu"))
      refute found?(doc, role("thumb") <> " " <> role("menu"))
      [trigger_class] = attr(doc, "#{role("menu")} [data-row-menu-trigger]", "class")
      assert trigger_class =~ "btn-sm"
      refute trigger_class =~ "opacity-0"
      refute trigger_class =~ "btn-xs"
    end

    test "the menu trigger is centred against the thumbnail, in every size and shape" do
      {folder, file} = folder_and_file()

      for size <- [:sm, :md, :lg], shape <- [:square, :circle] do
        doc =
          render_fi(
            uuid: file.uuid,
            picker_scope: {:folder, folder.uuid},
            size: size,
            shape: shape
          )

        # one row holds the thumbnail and the menu as siblings, centre-aligned
        assert [row_class] = attr(doc, role("row"), "class")
        assert row_class =~ "items-center"
        refute row_class =~ "items-start"
        assert found?(doc, "#{role("row")} > #{role("thumb")}")
        assert found?(doc, "#{role("row")} > #{role("menu")}")

        # ...while the root keeps left-aligning what sits below the row (the error line)
        assert [root_class] = attr(doc, "#fi", "class")
        assert root_class =~ "items-start"
      end
    end

    test "the row is centred whatever is drawn beside the menu: missing and processing too" do
      {folder, processing} = folder_and_file(%{status: "processing"})
      scope = {:folder, folder.uuid}

      for uuid <- [Ecto.UUID.generate(), processing.uuid] do
        doc = render_fi(uuid: uuid, picker_scope: scope)

        assert attr(doc, role("row"), "class") |> hd() =~ "items-center"
        assert found?(doc, "#{role("row")} > #{role("menu")}")
      end
    end

    test "the menu offers Change and Remove, and no View without on_preview" do
      {folder, file} = folder_and_file()
      doc = render_fi(uuid: file.uuid, picker_scope: {:folder, folder.uuid})

      assert attr(doc, role("change"), "phx-click") == ["open_picker"]
      assert attr(doc, role("remove"), "phx-click") == ["clear"]
      refute found?(doc, role("view"))

      for name <- ["change", "remove"] do
        assert attr(doc, role(name), "phx-target") != []
        assert attr(doc, role(name), "type") == ["button"]
      end
    end

    test "on_preview values become phx-value-* attributes; a non-scalar is dropped, not a crash" do
      {folder, file} = folder_and_file()

      doc =
        render_fi(
          uuid: file.uuid,
          picker_scope: {:folder, folder.uuid},
          on_preview: {"preview", %{uuid: "abc", n: 7, nested: %{a: 1}, list: [1]}}
        )

      assert attr(doc, role("thumb"), "phx-value-uuid") == ["abc"]
      assert attr(doc, role("thumb"), "phx-value-n") == ["7"]
      assert attr(doc, role("thumb"), "phx-value-nested") == []
      assert attr(doc, role("thumb"), "phx-value-list") == []
    end

    test "size picks the thumbnail variant and the box: 48 / 64 / 96 px" do
      {folder, file} = folder_and_file()

      for {size, box, variant} <- [
            {:sm, "size-12", "thumbnail"},
            {:md, "size-16", "thumbnail"},
            {:lg, "size-24", "small"}
          ] do
        doc = render_fi(uuid: file.uuid, picker_scope: {:folder, folder.uuid}, size: size)

        [classes] = attr(doc, role("thumb"), "class")
        assert classes =~ box
        assert [src] = attr(doc, role("thumb-img"), "src")
        assert src =~ "/file/#{file.uuid}/#{variant}/"
      end
    end

    test "the menu trigger grows with the thumbnail" do
      {folder, file} = folder_and_file()

      [sm] =
        attr(
          render_fi(uuid: file.uuid, picker_scope: {:folder, folder.uuid}, size: :md),
          "#{role("menu")} [data-row-menu-trigger]",
          "class"
        )

      [lg] =
        attr(
          render_fi(uuid: file.uuid, picker_scope: {:folder, folder.uuid}, size: :lg),
          "#{role("menu")} [data-row-menu-trigger]",
          "class"
        )

      assert sm =~ "btn-sm"
      assert lg =~ "btn-md"
    end

    test "shape :circle rounds the frame fully, :square (default) uses rounded-lg" do
      {folder, file} = folder_and_file()

      [circle] =
        attr(
          render_fi(uuid: file.uuid, picker_scope: {:folder, folder.uuid}, shape: :circle),
          role("thumb"),
          "class"
        )

      [square] =
        attr(
          render_fi(uuid: file.uuid, picker_scope: {:folder, folder.uuid}),
          role("thumb"),
          "class"
        )

      assert circle =~ "rounded-full"
      refute circle =~ "rounded-lg"
      assert square =~ "rounded-lg"
      refute square =~ "rounded-full"
    end

    test "a saved rotation is applied to the thumbnail like everywhere else" do
      {folder, file} = folder_and_file(%{metadata: %{"rotation" => 90}})
      doc = render_fi(uuid: file.uuid, picker_scope: {:folder, folder.uuid})

      assert [classes] = attr(doc, role("thumb-img"), "class")
      assert classes =~ "rotate-90"
    end

    test "confirm_remove puts a data-confirm on Remove only" do
      {folder, file} = folder_and_file()

      doc =
        render_fi(
          uuid: file.uuid,
          picker_scope: {:folder, folder.uuid},
          confirm_remove: "Remove this photo?"
        )

      assert attr(doc, role("remove"), "data-confirm") == ["Remove this photo?"]
      assert attr(doc, role("change"), "data-confirm") == []

      plain = render_fi(uuid: file.uuid, picker_scope: {:folder, folder.uuid})
      assert attr(plain, role("remove"), "data-confirm") == []
    end

    test "without a choosable scope the menu keeps Remove but drops Change" do
      {_folder, file} = folder_and_file()
      doc = render_fi(uuid: file.uuid, picker_scope: nil)

      assert found?(doc, role("remove"))
      refute found?(doc, role("change"))
    end

    test "readonly shows only the thumbnail: no menu, no picker" do
      {folder, file} = folder_and_file()
      doc = render_fi(uuid: file.uuid, picker_scope: {:folder, folder.uuid}, readonly: true)

      assert found?(doc, role("thumb-img"))
      refute found?(doc, role("menu"))
      refute found?(doc, role("change"))
      refute found?(doc, role("remove"))
      refute found?(doc, "#fi-portal")
    end

    test "a thumbnail with nowhere to go (readonly, no on_preview) is not a button" do
      {folder, file} = folder_and_file()
      doc = render_fi(uuid: file.uuid, picker_scope: {:folder, folder.uuid}, readonly: true)

      assert attr(doc, role("thumb"), "phx-click") == []
    end

    test "without on_preview a click on the thumbnail opens the picker" do
      {folder, file} = folder_and_file()
      doc = render_fi(uuid: file.uuid, picker_scope: {:folder, folder.uuid})

      assert attr(doc, role("thumb"), "phx-click") == ["open_picker"]
      assert attr(doc, role("thumb"), "type") == ["button"]
    end

    test "every button the component renders is type=button (it lives inside host forms)" do
      {folder, file} = folder_and_file()

      for attrs <- [
            [picker_scope: :lazy],
            [uuid: file.uuid, picker_scope: {:folder, folder.uuid}, on_preview: "preview"],
            [uuid: "gone", picker_scope: nil]
          ] do
        doc = render_fi(attrs)

        assert doc |> LazyHTML.query("button") |> LazyHTML.attribute("type") |> Enum.uniq() == [
                 "button"
               ]
      end
    end
  end

  describe "render — display guard" do
    test "a trashed file is dangling: no <img>, a placeholder, and a menu that can Remove" do
      {folder, file} = folder_and_file(%{status: "trashed"})
      doc = render_fi(uuid: file.uuid, picker_scope: {:folder, folder.uuid})

      assert state(doc) == "dangling"
      refute found?(doc, role("thumb-img"))
      assert found?(doc, role("dangling"))
      assert attr(doc, role("remove"), "phx-click") == ["clear"]
      assert found?(doc, role("change"))
    end

    test "dangling: a uuid with no row, a non-image file and a failed file" do
      {folder, video} = folder_and_file(%{file_type: "video", mime_type: "video/mp4", ext: "mp4"})
      failed = create_file!(folder.uuid, %{status: "failed"})

      for uuid <- [Ecto.UUID.generate(), video.uuid, failed.uuid] do
        doc = render_fi(uuid: uuid, picker_scope: {:folder, folder.uuid})

        assert state(doc) == "dangling"
        refute found?(doc, role("thumb-img"))
        assert found?(doc, role("remove"))
      end
    end

    test "a pointer that is not a UUID does not crash the render" do
      for junk <- ["not-a-uuid", 42, :atom, %{}] do
        doc = render_fi(uuid: junk, picker_scope: :lazy)

        assert state(doc) == "dangling"
        assert found?(doc, role("remove"))
      end
    end

    test "an empty string means \"cleared\", like nil" do
      doc = render_fi(uuid: "", picker_scope: :lazy)

      assert state(doc) == "empty"
      assert found?(doc, role("open-picker"))
      refute found?(doc, role("remove"))
    end

    test "a read-only viewer gets no warning for a missing image — and no menu" do
      doc = render_fi(uuid: Ecto.UUID.generate(), readonly: true)

      assert state(doc) == "dangling"
      refute found?(doc, role("dangling"))
      refute found?(doc, role("empty"))
      refute found?(doc, role("menu"))
      refute found?(doc, "img")
      # an empty box, not a labelled group with nothing in it
      assert attr(doc, "#fi", "role") == []
      assert attr(doc, "#fi", "aria-label") == []
    end

    test "with an :empty slot a missing image keeps the host's placeholder, marked, with Remove" do
      view = open_host(%{uuid: Ecto.UUID.generate(), picker_scope: :lazy}, slots: [:empty])

      assert has_element?(view, "#fi[data-state=dangling]")
      assert has_element?(view, "#{role("dangling")} [data-role=initials]")
      # marked for screen readers and by title, not by a warning box
      html = view |> element(role("dangling")) |> render()
      assert html =~ "sr-only"
      assert html =~ ~s(title=")
      refute html =~ "border-warning"
      assert has_element?(view, role("remove"))
    end

    test "a read-only viewer of a missing image still sees the :empty slot, without a menu" do
      view =
        open_host(%{uuid: Ecto.UUID.generate(), picker_scope: :lazy, readonly: true},
          slots: [:empty]
        )

      assert has_element?(view, "[data-role=initials]")
      refute has_element?(view, role("menu"))
      refute has_element?(view, role("dangling"))
    end

    test "processing draws a spinner instead of an <img>, and the menu can still Remove" do
      {folder, file} = folder_and_file(%{status: "processing"})
      doc = render_fi(uuid: file.uuid, picker_scope: {:folder, folder.uuid})

      assert state(doc) == "processing"
      assert found?(doc, role("processing"))
      # a live region with text in it, so it is announced
      assert doc |> LazyHTML.query(role("processing")) |> LazyHTML.text() =~ "Processing image…"
      refute found?(doc, role("thumb-img"))
      assert found?(doc, role("remove"))
    end
  end

  describe "the accessible name" do
    test "the control is a labelled group: the default label, a custom one, a translated one" do
      assert attr(render_fi(picker_scope: :lazy), "[role=group]", "aria-label") == [
               "Featured image"
             ]

      assert attr(
               render_fi(picker_scope: :lazy, label: "Company logo"),
               "[role=group]",
               "aria-label"
             ) ==
               ["Company logo"]

      Gettext.with_locale(PhoenixKitWeb.Gettext, "ru", fn ->
        assert attr(render_fi(picker_scope: :lazy), "[role=group]", "aria-label") ==
                 ["Главное изображение"]
      end)
    end
  end

  describe "when the host re-renders around a pending click or an error line" do
    test "a wait for the host ends when the host hands over a folder without answering" do
      {folder, _} = folder_and_file()
      view = open_host(%{picker_scope: :lazy}, lazy: :silent)
      choose = role("open-picker")

      view |> element(choose) |> render_click()
      assert has_element?(view, "#{choose}[aria-busy=true]")
      assert has_element?(view, "#{choose} .loading")

      send(view.pid, {:put_attr, :picker_scope, {:folder, folder.uuid}})
      settle(view)

      assert has_element?(view, "#{choose}[aria-busy=false]")
      refute has_element?(view, "#{choose} .loading")

      view |> element(choose) |> render_click()
      assert has_element?(view, "#fi-portal")
    end

    test "an error line set before the control turned read-only is not shown to the viewer" do
      view = open_host(%{picker_scope: :lazy}, lazy: {:error, "Restore this contact first"})

      view |> element(role("open-picker")) |> render_click()
      assert has_element?(view, role("error"))

      send(view.pid, {:put_attr, :readonly, true})
      settle(view)

      refute has_element?(view, role("error"))
    end
  end

  describe "translations" do
    test "the control speaks the reader's language (ru, et), from PhoenixKitWeb.Gettext" do
      {folder, file} = folder_and_file()

      for {locale, choose, remove, missing} <- [
            {"ru", "Выбрать изображение", "Удалить изображение", "Изображение отсутствует"},
            {"et", "Vali pilt", "Eemalda pilt", "Pilt puudub"}
          ] do
        Gettext.with_locale(PhoenixKitWeb.Gettext, locale, fn ->
          empty = render_fi(picker_scope: {:folder, folder.uuid})
          assert attr(empty, role("open-picker"), "title") == [choose]

          set = render_fi(uuid: file.uuid, picker_scope: {:folder, folder.uuid})
          assert set |> LazyHTML.query(role("remove")) |> LazyHTML.text() =~ remove

          dangling = render_fi(uuid: Ecto.UUID.generate())
          assert attr(dangling, role("dangling"), "title") == [missing]
        end)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Guard memoization and the `processing` re-check
  # ---------------------------------------------------------------------------

  describe "display guard — memoization" do
    test "one lookup per uuid: a re-render with the same uuid does not re-query" do
      {folder, file} = folder_and_file()
      attrs = %{uuid: file.uuid, picker_scope: {:folder, folder.uuid}}

      socket = socket_for(attrs)
      assert socket.assigns.display == :ok

      # the file goes to the trash behind the component's back
      set_status!(file, "trashed")

      {:ok, same} = FeaturedImage.update(Map.put(attrs, :id, "fi"), socket)
      assert same.assigns.display == :ok

      # a different uuid is looked up afresh
      {:ok, other} = FeaturedImage.update(%{id: "fi", uuid: Ecto.UUID.generate()}, same)
      assert other.assigns.display == :dangling
    end

    test "a `processing` file is not memoized: the next general update looks again" do
      {folder, file} = folder_and_file(%{status: "processing"})
      attrs = %{uuid: file.uuid, picker_scope: {:folder, folder.uuid}}

      socket = socket_for(attrs)
      assert socket.assigns.display == :processing

      set_status!(file, "active")

      {:ok, socket} = FeaturedImage.update(Map.put(attrs, :id, "fi"), socket)
      assert socket.assigns.display == :ok
    end

    test "changing uuid clears a stale error line" do
      {folder, file} = folder_and_file()
      socket = socket_for(uuid: nil, picker_scope: {:folder, folder.uuid})
      {:ok, socket} = FeaturedImage.update(%{id: "fi", error: "boom"}, socket)
      assert socket.assigns.error == "boom"

      {:ok, socket} = FeaturedImage.update(%{id: "fi", uuid: file.uuid}, socket)
      assert socket.assigns.error == nil
    end
  end

  describe "display guard — when the look-up cannot be made" do
    test "a database error is drawn as missing but not remembered; the next render recovers" do
      {folder, file} = folder_and_file()
      attrs = %{uuid: file.uuid, picker_scope: {:folder, folder.uuid}}
      parent = self()

      {socket, log} =
        with_log(fn ->
          # a process that was never allowed onto this test's sandbox connection
          spawn(fn -> send(parent, {:socket, socket_for(attrs)}) end)
          assert_receive {:socket, socket}, 2_000
          socket
        end)

      assert log =~ "could not load file"
      assert socket.assigns.display == :dangling
      assert socket.assigns.display_for == nil

      {:ok, socket} = FeaturedImage.update(Map.put(attrs, :id, "fi"), socket)
      assert socket.assigns.display == :ok
    end

    test "a junk uuid is an ordinary, remembered answer — not a look-up failure" do
      {socket, log} = with_log(fn -> socket_for(uuid: "not-a-uuid") end)

      assert socket.assigns.display == :dangling
      assert socket.assigns.display_for == {:memo, "not-a-uuid"}
      refute log =~ "could not load file"
    end
  end

  describe "processing — re-check" do
    test "becomes ok once the file finishes processing, without the host doing anything" do
      {folder, file} = folder_and_file(%{status: "processing"})
      view = open_host(%{id: "fi", uuid: file.uuid, picker_scope: {:folder, folder.uuid}})

      assert has_element?(view, "#fi[data-state=processing]")
      refute has_element?(view, role("thumb-img"))

      set_status!(file, "active")
      Phoenix.LiveView.send_update(view.pid, FeaturedImage, id: "fi", recheck: true)
      render(view)

      assert has_element?(view, "#fi[data-state=ok]")
      assert has_element?(view, role("thumb-img"))
    end

    test "gives up after 10 re-checks and turns dangling, so the pointer can be removed" do
      {folder, file} = folder_and_file(%{status: "processing"})
      socket = socket_for(uuid: file.uuid, picker_scope: {:folder, folder.uuid})

      socket =
        Enum.reduce(1..9, socket, fn _, socket ->
          {:ok, socket} = FeaturedImage.update(%{id: "fi", recheck: true}, socket)
          assert socket.assigns.display == :processing
          socket
        end)

      {:ok, socket} = FeaturedImage.update(%{id: "fi", recheck: true}, socket)
      assert socket.assigns.display == :dangling
    end

    test "one real timer is armed however often the host re-renders, and it re-checks the right instance" do
      {folder, file} = folder_and_file(%{status: "processing"})
      attrs = %{id: "fi", uuid: file.uuid, picker_scope: {:folder, folder.uuid}}

      socket = socket_for(attrs)
      assert socket.assigns.recheck_scheduled == true

      {:ok, socket} = FeaturedImage.update(attrs, socket)
      {:ok, _socket} = FeaturedImage.update(attrs, socket)

      # `send_update_after/3` delivers to the calling process, which here is
      # the test; the wait is the component's real 3-second interval.
      assert_receive {:phoenix, :send_update, {{FeaturedImage, "fi"}, %{recheck: true}}}, 4_000
      refute_receive {:phoenix, :send_update, _}, 200
    end

    test "a re-check that arrives after the file settled is a no-op" do
      {folder, file} = folder_and_file()
      socket = socket_for(uuid: file.uuid, picker_scope: {:folder, folder.uuid})

      {:ok, again} = FeaturedImage.update(%{id: "fi", recheck: true}, socket)
      assert again.assigns.display == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Slots
  # ---------------------------------------------------------------------------

  describe "slots" do
    test ":empty replaces the placeholder and is still what opens the picker" do
      {folder, _} = folder_and_file()
      view = open_host(%{picker_scope: {:folder, folder.uuid}}, slots: [:empty])

      assert has_element?(view, "#{role("open-picker")} [data-role=initials]")
    end

    test ":empty is drawn for a viewer too (readonly), just not clickable" do
      view = open_host(%{picker_scope: :lazy, readonly: true}, slots: [:empty])

      assert has_element?(view, "[data-role=initials]")
      refute has_element?(view, role("open-picker"))
    end

    test ":empty_hint shows when the picker is unavailable, and wins over :empty" do
      view = open_host(%{picker_scope: nil}, slots: [:empty, :empty_hint])

      assert has_element?(view, "[data-role=upload-first]")
      refute has_element?(view, "[data-role=initials]")
    end

    test ":empty is shown with no action when the picker is unavailable and there is no hint" do
      view = open_host(%{picker_scope: nil}, slots: [:empty])

      assert has_element?(view, "[data-role=initials]")
      refute has_element?(view, role("open-picker"))
    end

    test ":empty_hint is not drawn at all for readonly — readonly outranks it" do
      view = open_host(%{picker_scope: nil, readonly: true}, slots: [:empty_hint])

      refute has_element?(view, "[data-role=upload-first]")
    end

    test ":empty_hint is not drawn when the picker is available" do
      view = open_host(%{picker_scope: :lazy}, slots: [:empty_hint])

      refute has_element?(view, "[data-role=upload-first]")
      assert has_element?(view, role("open-picker"))
    end
  end

  # ---------------------------------------------------------------------------
  # Events and update clauses — direct calls
  # ---------------------------------------------------------------------------

  describe "media_selected" do
    test "sends {:set_featured, uuid} to the host and closes the picker" do
      {folder, file} = folder_and_file()

      socket =
        socket_for(picker_scope: {:folder, folder.uuid})
        |> Phoenix.Component.assign(:show_picker, true)

      {:ok, socket} = FeaturedImage.update(%{id: "fi", media_selected: [file.uuid]}, socket)

      assert_received {FeaturedImage, "fi", {:set_featured, uuid}}
      assert uuid == file.uuid
      assert socket.assigns.show_picker == false
      # controlled: the component itself does not adopt the choice
      assert socket.assigns.uuid == nil
    end

    test "the message carries this instance's id" do
      {folder, file} = folder_and_file()
      socket = socket_for(id: "second", picker_scope: {:folder, folder.uuid})

      {:ok, _} = FeaturedImage.update(%{id: "second", media_selected: [file.uuid]}, socket)

      assert_received {FeaturedImage, "second", {:set_featured, _}}
      refute_received {FeaturedImage, "fi", _}
    end

    test "an empty selection just closes: nothing is sent, and it never clears the pointer" do
      {folder, file} = folder_and_file()

      socket =
        socket_for(uuid: file.uuid, picker_scope: {:folder, folder.uuid})
        |> Phoenix.Component.assign(:show_picker, true)

      {:ok, socket} = FeaturedImage.update(%{id: "fi", media_selected: []}, socket)

      assert socket.assigns.show_picker == false
      assert mailbox() == []
    end

    test "choosing what is already set sends nothing" do
      {folder, file} = folder_and_file()

      socket =
        socket_for(uuid: file.uuid, picker_scope: {:folder, folder.uuid})
        |> Phoenix.Component.assign(:show_picker, true)

      {:ok, socket} = FeaturedImage.update(%{id: "fi", media_selected: [file.uuid]}, socket)

      assert socket.assigns.show_picker == false
      assert mailbox() == []
    end

    test "rejects a trashed, non-image, failed, missing or malformed choice with an error line" do
      {folder, video} = folder_and_file(%{file_type: "video", mime_type: "video/mp4", ext: "mp4"})
      trashed = create_file!(folder.uuid, %{status: "trashed"})
      failed = create_file!(folder.uuid, %{status: "failed"})

      for uuid <- [trashed.uuid, video.uuid, failed.uuid, Ecto.UUID.generate(), "not-a-uuid"] do
        socket =
          socket_for(picker_scope: {:folder, folder.uuid})
          |> Phoenix.Component.assign(:show_picker, true)

        {:ok, socket} = FeaturedImage.update(%{id: "fi", media_selected: [uuid]}, socket)

        assert socket.assigns.show_picker == false
        assert is_binary(socket.assigns.error) and socket.assigns.error != ""

        assert mailbox() == [],
               "a rejected choice #{inspect(uuid)} must reach the host as nothing"
      end
    end

    test "the error line clears the next time the picker opens" do
      {folder, file} = folder_and_file(%{status: "trashed"})
      socket = socket_for(picker_scope: {:folder, folder.uuid})
      {:ok, socket} = FeaturedImage.update(%{id: "fi", media_selected: [file.uuid]}, socket)
      assert socket.assigns.error

      {:noreply, socket} = FeaturedImage.handle_event("open_picker", %{}, socket)
      assert socket.assigns.error == nil
      assert socket.assigns.show_picker == true
    end

    test "an accepted choice that is still `processing` is passed on" do
      {folder, file} = folder_and_file(%{status: "processing"})
      socket = socket_for(picker_scope: {:folder, folder.uuid})

      {:ok, _socket} = FeaturedImage.update(%{id: "fi", media_selected: [file.uuid]}, socket)

      assert_received {FeaturedImage, "fi", {:set_featured, _}}
    end
  end

  describe "media_selector_closed" do
    test "closes the picker and sends nothing" do
      {folder, _} = folder_and_file()

      socket =
        socket_for(picker_scope: {:folder, folder.uuid})
        |> Phoenix.Component.assign(:show_picker, true)

      {:ok, socket} = FeaturedImage.update(%{id: "fi", media_selector_closed: true}, socket)

      assert socket.assigns.show_picker == false
      assert mailbox() == []
    end
  end

  describe "picker_closed (report_close)" do
    test "is sent only when the host opted in" do
      {folder, file} = folder_and_file()
      base = [picker_scope: {:folder, folder.uuid}]

      {:ok, _} =
        FeaturedImage.update(%{id: "fi", media_selector_closed: true}, socket_for(base))

      {:ok, _} =
        FeaturedImage.update(%{id: "fi", media_selected: [file.uuid]}, socket_for(base))

      refute_received {FeaturedImage, _, :picker_closed}

      opted_in = socket_for([report_close: true] ++ base)

      {:ok, _} = FeaturedImage.update(%{id: "fi", media_selector_closed: true}, opted_in)
      assert_received {FeaturedImage, "fi", :picker_closed}
    end

    test "follows :set_featured, so a host refreshes its file list after the pointer" do
      {folder, file} = folder_and_file()
      socket = socket_for(report_close: true, picker_scope: {:folder, folder.uuid})

      {:ok, _} = FeaturedImage.update(%{id: "fi", media_selected: [file.uuid]}, socket)

      assert mailbox() == [
               {FeaturedImage, "fi", {:set_featured, file.uuid}},
               {FeaturedImage, "fi", :picker_closed}
             ]
    end

    test "is sent for every way of closing, including a rejected choice and an empty one" do
      {folder, trashed} = folder_and_file(%{status: "trashed"})
      base = [report_close: true, picker_scope: {:folder, folder.uuid}]

      {:ok, _} =
        FeaturedImage.update(%{id: "fi", media_selected: [trashed.uuid]}, socket_for(base))

      assert mailbox() == [{FeaturedImage, "fi", :picker_closed}]
      flush_mailbox()

      {:ok, _} = FeaturedImage.update(%{id: "fi", media_selected: []}, socket_for(base))
      assert mailbox() == [{FeaturedImage, "fi", :picker_closed}]
    end
  end

  describe "clear" do
    test "sends {:set_featured, nil} to the host" do
      {folder, file} = folder_and_file()
      socket = socket_for(uuid: file.uuid, picker_scope: {:folder, folder.uuid})

      {:noreply, _socket} = FeaturedImage.handle_event("clear", %{}, socket)

      assert_received {FeaturedImage, "fi", {:set_featured, nil}}
    end

    test "works on a dangling pointer — that is the whole point of the Remove item" do
      socket = socket_for(uuid: Ecto.UUID.generate())

      {:noreply, _socket} = FeaturedImage.handle_event("clear", %{}, socket)

      assert_received {FeaturedImage, "fi", {:set_featured, nil}}
    end

    test "with nothing set there is nothing to clear" do
      {:noreply, _socket} = FeaturedImage.handle_event("clear", %{}, socket_for(uuid: nil))

      assert mailbox() == []
    end
  end

  describe "open_picker event" do
    test "opens the picker for a {:folder, uuid} scope" do
      {folder, _} = folder_and_file()

      {:noreply, socket} =
        FeaturedImage.handle_event(
          "open_picker",
          %{},
          socket_for(picker_scope: {:folder, folder.uuid})
        )

      assert socket.assigns.show_picker == true
      assert mailbox() == []
    end

    test "does nothing when the picker is unavailable (picker_scope nil): never the whole library" do
      {:noreply, socket} =
        FeaturedImage.handle_event("open_picker", %{}, socket_for(picker_scope: nil))

      assert socket.assigns.show_picker == false
      assert mailbox() == []
    end
  end

  describe "readonly" do
    setup do
      {folder, file} = folder_and_file()
      other = create_file!(folder.uuid)

      socket =
        socket_for(
          uuid: file.uuid,
          picker_scope: {:folder, folder.uuid},
          readonly: true,
          report_close: true
        )

      %{socket: socket, other: other, folder: folder}
    end

    test "events are no-ops", %{socket: socket} do
      {:noreply, opened} = FeaturedImage.handle_event("open_picker", %{}, socket)
      assert opened.assigns.show_picker == false

      {:noreply, _} = FeaturedImage.handle_event("clear", %{}, socket)

      assert mailbox() == []
    end

    test "a forged media_selected changes nothing and sends nothing", %{
      socket: socket,
      other: other
    } do
      {:ok, socket} = FeaturedImage.update(%{id: "fi", media_selected: [other.uuid]}, socket)

      assert socket.assigns.show_picker == false
      assert mailbox() == []
    end

    test "a media_selector_closed that races the flip closes quietly", %{socket: socket} do
      socket = Phoenix.Component.assign(socket, :show_picker, true)

      {:ok, socket} = FeaturedImage.update(%{id: "fi", media_selector_closed: true}, socket)

      assert socket.assigns.show_picker == false
      assert mailbox() == []
    end

    test "open_picker: true and error: are ignored", %{socket: socket} do
      {:ok, socket} = FeaturedImage.update(%{id: "fi", open_picker: true}, socket)
      assert socket.assigns.show_picker == false

      {:ok, socket} = FeaturedImage.update(%{id: "fi", error: "nope"}, socket)
      assert socket.assigns.error == nil
    end

    test "a picker left open when readonly flips on is closed by the next render", %{
      socket: socket
    } do
      open =
        Phoenix.Component.assign(socket, :readonly, false)
        |> Phoenix.Component.assign(:show_picker, true)

      {:ok, socket} = FeaturedImage.update(%{id: "fi", readonly: true}, open)

      assert socket.assigns.show_picker == false
    end
  end

  # ---------------------------------------------------------------------------
  # Lazy scope handshake — through a real LiveView
  # ---------------------------------------------------------------------------

  describe "picker_scope: :lazy" do
    test "a click asks the host for a scope and does not open the picker" do
      view = open_host(%{picker_scope: :lazy}, lazy: :silent)

      view |> element(role("open-picker")) |> render_click()

      assert_receive :scope_requested_received
      refute has_element?(view, "#fi-portal")
    end

    test "the host's open_picker: true opens it once its scope attr is a folder" do
      {folder, _} = folder_and_file()
      view = open_host(%{picker_scope: :lazy}, lazy: {:grant, folder.uuid})

      view |> element(role("open-picker")) |> render_click()
      settle(view)

      assert has_element?(view, "#fi-portal")
      assert render(element(view, "#fi-portal")) =~ "media-selector-modal-backdrop-fi-selector"
    end

    test "open_picker: true while the scope is still :lazy opens nothing, and says why" do
      view = open_host(%{picker_scope: :lazy}, lazy: :grant_without_folder)

      log =
        capture_log(fn ->
          view |> element(role("open-picker")) |> render_click()
          settle(view)
        end)

      refute has_element?(view, "#fi-portal")
      assert log =~ "open_picker: true arrived"
    end

    test "open_picker: false (the host refuses and shows its own flash) opens nothing, no error line" do
      view = open_host(%{picker_scope: :lazy}, lazy: :deny)

      view |> element(role("open-picker")) |> render_click()
      settle(view)

      assert_receive :scope_requested_received
      refute has_element?(view, "#fi-portal")
      refute has_element?(view, role("error"))
    end

    test "error: shows the host's message under the control and opens nothing" do
      view = open_host(%{picker_scope: :lazy}, lazy: {:error, "Restore this contact first"})

      view |> element(role("open-picker")) |> render_click()

      assert view |> element(role("error")) |> render() =~ "Restore this contact first"
      assert has_element?(view, "#{role("error")}[role=alert]")
      refute has_element?(view, "#fi-portal")
    end

    test "a second click while the answer is pending is a no-op" do
      view = open_host(%{picker_scope: :lazy}, lazy: :silent)

      view |> element(role("open-picker")) |> render_click()
      view |> element(role("open-picker")) |> render_click()

      assert_receive :scope_requested_received
      refute_receive :scope_requested_received, 50
    end

    test "after a refusal the control works again" do
      view = open_host(%{picker_scope: :lazy}, lazy: :deny)

      view |> element(role("open-picker")) |> render_click()
      settle(view)
      view |> element(role("open-picker")) |> render_click()

      assert_receive :scope_requested_received
      assert_receive :scope_requested_received
    end

    test "a click with a folder scope already in place never asks the host" do
      {folder, _} = folder_and_file()
      view = open_host(%{picker_scope: {:folder, folder.uuid}}, lazy: :silent)

      view |> element(role("open-picker")) |> render_click()

      refute_receive :scope_requested_received, 50
      assert has_element?(view, "#fi-portal")
    end
  end

  # ---------------------------------------------------------------------------
  # on_preview — a real click on the real element
  # ---------------------------------------------------------------------------

  describe "on_preview" do
    test "{event, values} — a click on the thumbnail reaches the host with the values as params" do
      {folder, file} = folder_and_file()
      sub_order = Ecto.UUID.generate()

      view =
        open_host(%{
          uuid: file.uuid,
          picker_scope: {:folder, folder.uuid},
          on_preview: {"preview", %{uuid: sub_order}}
        })

      view |> element(role("thumb")) |> render_click()

      assert_receive {:preview, %{"uuid" => ^sub_order}}
    end

    test "a plain event name is pushed to the host" do
      {folder, file} = folder_and_file()

      view =
        open_host(%{uuid: file.uuid, picker_scope: {:folder, folder.uuid}, on_preview: "preview"})

      view |> element(role("thumb")) |> render_click()

      assert_receive {:preview, params}
      assert params == %{}
    end

    test "a %JS{} command is used as the click command" do
      {folder, file} = folder_and_file()
      js = JS.push("preview", value: %{uuid: "from-js"})

      view = open_host(%{uuid: file.uuid, picker_scope: {:folder, folder.uuid}, on_preview: js})

      view |> element(role("thumb")) |> render_click()

      assert_receive {:preview, %{"uuid" => "from-js"}}
    end

    test "the menu's View item pushes the same event with the same values" do
      {folder, file} = folder_and_file()

      view =
        open_host(%{
          uuid: file.uuid,
          picker_scope: {:folder, folder.uuid},
          on_preview: {"preview", %{uuid: "abc"}}
        })

      view |> element(role("view")) |> render_click()

      assert_receive {:preview, %{"uuid" => "abc"}}
    end

    test "the thumbnail keeps working for a viewer (readonly), with no menu" do
      {folder, file} = folder_and_file()

      view =
        open_host(%{
          uuid: file.uuid,
          picker_scope: {:folder, folder.uuid},
          readonly: true,
          on_preview: {"preview", %{uuid: "abc"}}
        })

      view |> element(role("thumb")) |> render_click()

      assert_receive {:preview, %{"uuid" => "abc"}}
      refute has_element?(view, role("menu"))
    end

    test "with on_preview set the thumbnail no longer opens the picker" do
      {folder, file} = folder_and_file()

      view =
        open_host(%{uuid: file.uuid, picker_scope: {:folder, folder.uuid}, on_preview: "preview"})

      view |> element(role("thumb")) |> render_click()

      refute has_element?(view, "#fi-portal")
    end

    test "a dangling or processing pointer offers no preview" do
      {folder, file} = folder_and_file(%{status: "trashed"})

      doc =
        render_fi(uuid: file.uuid, picker_scope: {:folder, folder.uuid}, on_preview: "preview")

      refute found?(doc, role("view"))
      refute found?(doc, role("thumb"))
    end
  end

  # ---------------------------------------------------------------------------
  # Inside a host <form phx-change> — the modal must not nest a <form>
  # ---------------------------------------------------------------------------

  describe "inside a host <form phx-change>" do
    test "the picker modal is portaled out, so the host form never holds a second form" do
      {folder, _} = folder_and_file()
      view = open_host(%{picker_scope: {:folder, folder.uuid}})

      refute has_element?(view, "#fi-portal")

      view |> element(role("open-picker")) |> render_click()

      assert has_element?(view, "#fi-portal")
      html = render(element(view, "#fi-portal"))
      assert html =~ ~s(data-phx-portal="body")
      assert html =~ "media-selector-modal-backdrop-fi-selector"
    end

    test "the menu's Change opens the picker and Remove reaches the host, from inside the form" do
      {folder, file} = folder_and_file()
      view = open_host(%{uuid: file.uuid, picker_scope: {:folder, folder.uuid}})

      view |> element(role("change")) |> render_click()
      assert has_element?(view, "#fi-portal")

      view |> element(role("remove")) |> render_click()
      assert_receive {:set_featured_received, nil}
    end
  end

  # ---------------------------------------------------------------------------
  # The picker itself
  # ---------------------------------------------------------------------------

  describe "picker" do
    test "is a locked, single-mode, images-only picker scoped to the folder, titled by the label" do
      folder = create_folder!()
      create_file!(folder.uuid, %{original_file_name: "mine.jpg"})
      # ten more, so the modal shows its search row (a locked picker hides it
      # below ten files) and the type switcher's absence means something
      for n <- 1..10, do: create_file!(folder.uuid, %{original_file_name: "bulk-#{n}.jpg"})

      create_file!(folder.uuid, %{
        original_file_name: "clip.mp4",
        file_type: "video",
        mime_type: "video/mp4",
        ext: "mp4"
      })

      create_file!(create_folder!().uuid, %{original_file_name: "elsewhere.jpg"})

      view = open_host(%{picker_scope: {:folder, folder.uuid}, label: "Company logo"})
      view |> element(role("open-picker")) |> render_click()
      html = render(element(view, "#fi-portal"))

      assert html =~ "Company logo"
      assert html =~ "mine.jpg"
      assert html =~ ~s(phx-dblclick="quick_confirm"), "expected single-select tiles"
      refute html =~ "clip.mp4", "expected images only"
      refute html =~ "elsewhere.jpg", "expected the picker scoped to the entity's folder"
      assert html =~ "media-selector-search-fi-selector"
      refute html =~ ~s(phx-change="filter_type"), "expected the file-type switcher locked away"
    end

    test "is not mounted while closed, nor for an unusable scope" do
      {folder, _} = folder_and_file()

      refute has_element?(open_host(%{picker_scope: {:folder, folder.uuid}}), "#fi-portal")
      refute has_element?(open_host(%{picker_scope: :lazy}), "#fi-portal")
      refute has_element?(open_host(%{picker_scope: nil}), "#fi-portal")
    end

    test "is not mounted when readonly, even if asked to open" do
      {folder, _} = folder_and_file()
      view = open_host(%{picker_scope: {:folder, folder.uuid}, readonly: true})

      Phoenix.LiveView.send_update(view.pid, FeaturedImage, id: "fi", open_picker: true)
      settle(view)

      refute has_element?(view, "#fi-portal")
    end

    test "preselects the current file, but never a dangling pointer" do
      {folder, file} = folder_and_file()
      gone = create_file!(folder.uuid, %{status: "trashed"})

      # A <template>'s content is not part of the parsed tree, so read the
      # portal's markup as text.
      confirm_disabled? = fn uuid ->
        view = open_host(%{uuid: uuid, picker_scope: {:folder, folder.uuid}})
        view |> element(role("change")) |> render_click()

        html = view |> element("#fi-portal") |> render()
        [tag] = Regex.run(~r/<button[^>]*phx-click="confirm_selection"[^>]*>/, html)
        tag =~ "disabled"
      end

      refute confirm_disabled?.(file.uuid), "a valid current file should arrive preselected"
      assert confirm_disabled?.(gone.uuid), "a trashed pointer must not be preselected"
    end
  end

  # ---------------------------------------------------------------------------
  # The full circle through a live host
  # ---------------------------------------------------------------------------

  describe "the real MediaSelectorModal, notifying the component" do
    # The component's own modal sits in a portal ExUnit cannot enter, so this
    # runs the real one next to it with the `notify` the component's template
    # passes — the modal → send_update → FeaturedImage.update seam.
    test "Confirm reaches the host as :set_featured, then :picker_closed, and the thumbnail follows" do
      {folder, file} = folder_and_file()

      view =
        open_host(%{picker_scope: {:folder, folder.uuid}, report_close: true}, direct_modal: true)

      view
      |> element("[phx-click=toggle_selection][phx-value-file-uuid='#{file.uuid}']")
      |> render_click()

      view |> element("[phx-click=confirm_selection]") |> render_click()
      settle(view)

      assert [{:set_featured_received, uuid}, :picker_closed_received] =
               Enum.filter(
                 mailbox(),
                 &(&1 == :picker_closed_received or match?({:set_featured_received, _}, &1))
               )

      assert uuid == file.uuid
      assert view |> element(role("thumb-img")) |> render() =~ file.uuid
    end

    test "Cancel reaches the host only as :picker_closed" do
      {folder, _file} = folder_and_file()

      view =
        open_host(%{picker_scope: {:folder, folder.uuid}, report_close: true}, direct_modal: true)

      view |> element("button[phx-click=close_modal]", "Cancel") |> render_click()
      settle(view)

      assert_receive :picker_closed_received
      refute_received {:set_featured_received, _}
    end
  end

  describe "full circle" do
    test "open → select → host stores → the new thumbnail appears and the picker is gone" do
      {folder, first} = folder_and_file()
      second = create_file!(folder.uuid)

      view = open_host(%{uuid: first.uuid, picker_scope: {:folder, folder.uuid}})
      assert view |> element(role("thumb-img")) |> render() =~ first.uuid

      view |> element(role("change")) |> render_click()
      assert has_element?(view, "#fi-portal")

      # what MediaSelectorModal does on Confirm when given `notify: {FeaturedImage, "fi"}`
      Phoenix.LiveView.send_update(view.pid, FeaturedImage,
        id: "fi",
        media_selected: [second.uuid]
      )

      html = settle(view)

      assert_receive {:set_featured_received, uuid}
      assert uuid == second.uuid
      refute has_element?(view, "#fi-portal")
      assert view |> element(role("thumb-img")) |> render() =~ second.uuid
      refute html =~ first.uuid
    end

    test "cancelling leaves the pointer alone and tells the host nothing (report_close off)" do
      {folder, file} = folder_and_file()
      view = open_host(%{uuid: file.uuid, picker_scope: {:folder, folder.uuid}})

      view |> element(role("change")) |> render_click()
      Phoenix.LiveView.send_update(view.pid, FeaturedImage, id: "fi", media_selector_closed: true)
      settle(view)

      refute has_element?(view, "#fi-portal")
      refute_received {:set_featured_received, _}
      refute_received :picker_closed_received
      assert view |> element(role("thumb-img")) |> render() =~ file.uuid
    end

    test "report_close: the host hears about a cancel" do
      {folder, file} = folder_and_file()

      view =
        open_host(%{uuid: file.uuid, picker_scope: {:folder, folder.uuid}, report_close: true})

      view |> element(role("change")) |> render_click()
      Phoenix.LiveView.send_update(view.pid, FeaturedImage, id: "fi", media_selector_closed: true)
      settle(view)

      assert_receive :picker_closed_received
    end

    test "Remove: the host gets nil and hands back a cleared uuid, which draws the empty control" do
      {folder, file} = folder_and_file()
      view = open_host(%{uuid: file.uuid, picker_scope: {:folder, folder.uuid}})

      view |> element(role("remove")) |> render_click()

      assert_receive {:set_featured_received, nil}
      assert has_element?(view, "#fi[data-state=empty]")
      assert has_element?(view, role("open-picker"))
    end

    test "a host that refuses the write and keeps its uuid keeps the old thumbnail" do
      {folder, file} = folder_and_file()
      other = create_file!(folder.uuid)

      # The host receives :set_featured but never hands a new uuid back: the
      # component must not paint the choice on its own.
      view =
        open_host(%{uuid: file.uuid, picker_scope: {:folder, folder.uuid}}, refuse_writes: true)

      Phoenix.LiveView.send_update(view.pid, FeaturedImage,
        id: "fi",
        media_selected: [other.uuid]
      )

      settle(view)

      assert_receive {:set_featured_received, uuid}
      assert uuid == other.uuid
      assert view |> element(role("thumb-img")) |> render() =~ file.uuid
    end
  end
end
