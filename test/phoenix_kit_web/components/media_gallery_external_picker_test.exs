defmodule PhoenixKitWeb.Components.MediaGalleryExternalPickerTest do
  @moduledoc """
  `MediaGallery` with `external_picker` inside a running LiveView: a real click
  on the Add tile reaches the host as `{:open_picker, …}`, the host answers with
  `send_update(MediaGallery, id: id, media_selected: uuids)`, and the gallery
  reports the new selection back as `{:changed, …}` — the whole host cycle.
  """

  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKitWeb.Components.MediaGallery

  @uuid1 "01900000-0000-7000-8000-000000000001"
  @uuid2 "01900000-0000-7000-8000-000000000002"
  @uuid3 "01900000-0000-7000-8000-000000000003"

  defmodule Host do
    @moduledoc false
    use Phoenix.LiveView

    alias PhoenixKitWeb.Components.MediaGallery

    # ConnCase's `using` block imports `Plug.Conn`, whose `assign/3` would make
    # a bare call ambiguous.
    defp set_assign(socket, key, value), do: Phoenix.Component.assign(socket, key, value)

    def mount(_params, session, socket) do
      {:ok,
       socket
       |> set_assign(:attrs, Map.new(session["attrs"]))
       |> set_assign(:answer, session["answer"])
       |> set_assign(:test_pid, session["test_pid"])}
    end

    # Stands in for the host's own picker: reports the request, then hands a
    # choice back the documented way (or answers nothing, like a cancel).
    def handle_info({MediaGallery, id, {:open_picker, request}}, socket) do
      send(socket.assigns.test_pid, {:open_picker_received, id, request})

      if socket.assigns.answer do
        Phoenix.LiveView.send_update(MediaGallery, id: id, media_selected: socket.assigns.answer)
      end

      {:noreply, socket}
    end

    # The gallery is controlled: the host stores the selection and passes it back.
    def handle_info({MediaGallery, _id, {:changed, uuids}}, socket) do
      send(socket.assigns.test_pid, {:changed_received, uuids})
      {:noreply, set_assign(socket, :attrs, Map.put(socket.assigns.attrs, :selected, uuids))}
    end

    def render(assigns) do
      ~H"""
      <.live_component module={MediaGallery} id="g" {@attrs} />
      """
    end
  end

  defp open_host(attrs, answer \\ nil) do
    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), Host,
        session: %{"attrs" => attrs, "answer" => answer, "test_pid" => self()}
      )

    view
  end

  @add ~s([data-role="open-picker-g"])
  @modal "#media-selector-modal-backdrop-g-media-selector"

  test "clicking Add asks the host instead of opening the built-in picker" do
    view = open_host(%{external_picker: true, selected: [@uuid1], max_count: 3})

    view |> element(@add) |> render_click()

    assert_receive {:open_picker_received, "g",
                    %{selected: [@uuid1], mode: :multiple, max_count: 3}}

    refute has_element?(view, @modal)
    refute_receive {:changed_received, _}, 50
  end

  test "the host's choice becomes the selection and comes back as :changed" do
    view =
      open_host(%{external_picker: true, selected: [@uuid1], max_count: 2}, [
        @uuid3,
        @uuid1,
        @uuid2
      ])

    view |> element(@add) |> render_click()

    assert_receive {:open_picker_received, "g", %{selected: [@uuid1]}}
    # A full replacement, clamped to max_count like the built-in picker's.
    assert_receive {:changed_received, [@uuid3, @uuid1]}

    html = render(view)
    assert html =~ ~s(data-id="#{@uuid3}")
    assert html =~ ~s(data-id="#{@uuid1}")
    refute html =~ ~s(data-id="#{@uuid2}")
    refute has_element?(view, @modal)
  end

  test "in :single mode the host's choice keeps only the first file" do
    view = open_host(%{external_picker: true, mode: :single}, [@uuid2, @uuid3])

    view |> element(@add) |> render_click()

    assert_receive {:open_picker_received, "g", %{selected: [], mode: :single, max_count: nil}}
    assert_receive {:changed_received, [@uuid2]}
  end

  test "a forged open_picker on a readonly gallery reaches no host" do
    view = open_host(%{external_picker: true, readonly: true, selected: [@uuid1]})

    refute has_element?(view, @add)

    view
    |> with_target("#g")
    |> render_click("open_picker", %{})

    refute_receive {:open_picker_received, _, _}, 50
    refute has_element?(view, @modal)
  end

  test "without external_picker, Add opens the built-in picker and tells the host nothing" do
    view = open_host(%{selected: []})

    view |> element(@add) |> render_click()

    assert has_element?(view, @modal)
    refute_receive {:open_picker_received, _, _}, 50
  end
end
