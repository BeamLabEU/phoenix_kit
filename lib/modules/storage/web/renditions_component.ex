defmodule PhoenixKitWeb.Live.Modules.Storage.RenditionsComponent do
  @moduledoc """
  The Renditions tab of Settings → Media (V205): rendition profiles and the
  renditions in them.

  A **rendition** is a smaller or re-encoded copy of an upload (a thumbnail, a
  720p video) made for faster loading; the code calls them variants, and the
  rows are `Storage.Dimension`s. A **rendition profile** (`Storage.VariantSet`) says
  which ones a library's uploads get, and whether they are made automatically
  after an upload. A library names its set when it is created and keeps it
  (Libraries tab → New library).

  One tab per set (`?tab=renditions&set=<uuid>`; none is the Default). The
  standard renditions are listed first and cannot be deleted. A new set starts
  with a copy of the Default's standard renditions. Changing a set or a
  rendition bumps the set's revision and the reconciler brings its files up to
  date; "Check every file" does that without a change (a rendition a file never
  got is made). Adding or editing one rendition is its own page
  (`DimensionForm`).

  Deep zoom (zoomable tiles) is not part of a set: it is a switch on the
  library's page.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Dimension, VariantSet, VariantSets}
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       scope: nil,
       active: false,
       set_uuid: nil,
       set: nil,
       creating: false
     )}
  end

  @impl true
  def update(assigns, socket) do
    was_active = socket.assigns.active
    socket = assign(socket, assigns)
    wanted = socket.assigns.set_uuid

    # Reopening the tab picks up edits made elsewhere while it was hidden.
    if is_nil(socket.assigns.set) or wanted != socket.assigns[:loaded_for] or
         (socket.assigns.active and not was_active) do
      set = (wanted && VariantSets.get_variant_set(wanted)) || default_set()
      {:ok, socket |> assign(:loaded_for, wanted) |> load_set(set)}
    else
      {:ok, socket}
    end
  end

  defp default_set, do: VariantSets.default_variant_set()

  defp load_set(socket, %VariantSet{} = set) do
    socket
    |> assign(:sets, VariantSets.list_variant_sets())
    |> assign(:set, set)
    |> assign(:set_libraries, VariantSets.libraries_using(set.uuid))
    |> assign(:missing_slots, VariantSets.missing_standard_slots(set.uuid))
    |> assign(:set_form, to_form(VariantSet.changeset(set, %{})))
    |> assign(:dimensions, pinned(Storage.list_dimensions(set.uuid)))
  end

  # The standard renditions first, each group in its order.
  defp pinned(dimensions) do
    {standard, custom} = Enum.split_with(dimensions, &Dimension.standard_slot?/1)
    standard ++ custom
  end

  defp reload(socket) do
    set = VariantSets.get_variant_set(socket.assigns.set.uuid) || default_set()
    load_set(socket, set)
  end

  # The client names a row, but it must still exist in the set being edited.
  defp dimension_in_set(socket, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Dimension{} = dimension <- Storage.get_dimension(uuid),
         true <- dimension.variant_set_uuid == socket.assigns.set.uuid do
      {:ok, dimension}
    else
      _ -> {:error, :not_found}
    end
  end

  # The tab has no flash of its own: the settings page puts it.
  defp flash(socket, kind, message) do
    send(self(), {__MODULE__, {:flash, kind, message}})
    socket
  end

  defp actor(socket), do: Actor.opts(socket.assigns.scope)

  @impl true
  def handle_event("delete_dimension", %{"id" => id}, socket) do
    result =
      with {:ok, dimension} <- dimension_in_set(socket, id),
           do: {Storage.delete_dimension(dimension, actor(socket)), dimension}

    case result do
      {{:ok, _}, _dimension} ->
        {:noreply, socket |> reload() |> flash(:info, gettext("Rendition deleted"))}

      {{:error, :standard_slot}, dimension} ->
        {:noreply,
         flash(
           socket,
           :error,
           gettext(
             "%{name} is a standard rendition every rendition profile has; it cannot be deleted",
             name: dimension.name
           )
         )}

      _error ->
        {:noreply, socket |> reload() |> flash(:error, gettext("Could not delete the rendition"))}
    end
  end

  def handle_event("toggle_dimension", %{"id" => id}, socket) do
    result =
      with {:ok, dimension} <- dimension_in_set(socket, id),
           do: Storage.update_dimension(dimension, %{enabled: !dimension.enabled}, actor(socket))

    case result do
      {:ok, _dimension} ->
        {:noreply, socket |> reload() |> flash(:info, gettext("Rendition updated"))}

      {:error, _changeset} ->
        {:noreply, socket |> reload() |> flash(:error, gettext("Could not update the rendition"))}
    end
  end

  def handle_event("reset_dimensions_to_defaults", _params, socket) do
    case Storage.reset_dimensions_to_defaults(actor(socket)) do
      {:ok, _} ->
        {:noreply,
         socket |> reload() |> flash(:info, gettext("Renditions reset to the standard ones"))}

      {:error, reason} ->
        {:noreply,
         flash(
           socket,
           :error,
           gettext("Could not reset renditions: %{reason}", reason: inspect(reason))
         )}
    end
  end

  def handle_event("new", _params, socket), do: {:noreply, assign(socket, :creating, true)}
  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, :creating, false)}

  def handle_event("create_set", %{"name" => name}, socket) do
    case VariantSets.create_variant_set(%{name: name}, actor(socket)) do
      {:ok, set} ->
        {:noreply,
         socket
         |> assign(:creating, false)
         |> flash(:info, gettext("Rendition profile created"))
         |> push_patch(to: set_path(set))}

      {:error, changeset} ->
        {:noreply, flash(socket, :error, first_error(changeset))}
    end
  end

  def handle_event("save_set", %{"variant_set" => params}, socket) do
    case VariantSets.update_variant_set(socket.assigns.set, params, actor(socket)) do
      {:ok, _set} ->
        {:noreply, socket |> reload() |> flash(:info, gettext("Rendition profile saved"))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :set_form, to_form(changeset))}

      {:error, _reason} ->
        {:noreply, socket |> reload() |> flash(:error, gettext("Could not save"))}
    end
  end

  def handle_event("delete_set", _params, socket) do
    case VariantSets.delete_variant_set(socket.assigns.set, actor(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> flash(:info, gettext("Rendition profile deleted"))
         |> push_patch(to: set_path(default_set()))}

      {:error, :in_use} ->
        {:noreply,
         flash(
           socket,
           :error,
           gettext("A library uses this rendition profile; it cannot be deleted")
         )}

      {:error, _} ->
        {:noreply, flash(socket, :error, gettext("This rendition profile cannot be deleted"))}
    end
  end

  def handle_event("check_set", _params, socket) do
    case VariantSets.check_files(socket.assigns.set, actor(socket)) do
      :ok ->
        {:noreply,
         socket
         |> reload()
         |> flash(
           :info,
           gettext(
             "Every file of this rendition profile will be checked, and missing renditions made."
           )
         )}

      {:error, _} ->
        {:noreply, flash(socket, :error, gettext("Could not save"))}
    end
  end

  defp first_error(%Ecto.Changeset{errors: [{field, {message, _}} | _]}),
    do: "#{Phoenix.Naming.humanize(field)} #{message}"

  defp first_error(_changeset), do: gettext("Could not save")

  @doc false
  # The tab for `set`: no set in the URL for the Default.
  def set_path(%VariantSet{is_default: true}),
    do: Routes.path("/admin/settings/media?tab=renditions")

  def set_path(%VariantSet{uuid: uuid}),
    do: Routes.path("/admin/settings/media?tab=renditions&set=#{uuid}")

  @doc false
  # A new-rendition form for `set` (`kind` is "image" or "video").
  def new_dimension_path(%VariantSet{is_default: true}, kind),
    do: Routes.path("/admin/settings/media/renditions/new/#{kind}")

  def new_dimension_path(%VariantSet{uuid: uuid}, kind),
    do: Routes.path("/admin/settings/media/renditions/new/#{kind}?set=#{uuid}")

  # What a rendition's size means, in words: `{size, note}`. One that keeps
  # proportions sets the width and lets the height follow each image or video;
  # a fixed image rendition is a box the image is scaled to fill and cropped to,
  # a fixed video one a box the video is scaled to fit inside. Neither enlarges.
  defp size_text(%{maintain_aspect_ratio: true, width: width}, kind) when is_integer(width) do
    {gettext("%{width} px wide", width: width),
     if(kind == :image,
       do: gettext("height follows the image"),
       else: gettext("height follows the video")
     )}
  end

  defp size_text(%{width: width, height: height}, kind)
       when is_integer(width) and is_integer(height) do
    {gettext("%{width} × %{height} px", width: width, height: height),
     if(kind == :image, do: gettext("cropped to fit"), else: gettext("fits inside, shape kept"))}
  end

  defp size_text(_dimension, _kind), do: {gettext("Automatic"), nil}

  # The same in one line, for the card layout.
  defp size_line(dimension, kind) do
    case size_text(dimension, kind) do
      {size, nil} -> size
      {size, note} -> "#{size} · #{note}"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="px-1 py-4">
      <%!-- What a rendition is, and the way to a new set --%>
      <div id={"#{@id}-about"} class="card bg-base-100 shadow-xl mb-6">
        <div class="card-body">
          <div class="flex flex-wrap justify-between items-center gap-2 mb-2">
            <h2 class="card-title text-lg">
              <.icon name="hero-arrows-pointing-out" class="w-6 h-6 mr-2" /> {gettext(
                "Rendition profiles"
              )}
            </h2>
            <button
              :if={not @creating}
              type="button"
              class="btn btn-primary"
              phx-click="new"
              phx-target={@myself}
            >
              <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext("New rendition profile")}
            </button>
          </div>
          <p class="text-sm text-base-content/70">
            {gettext(
              "A rendition is a smaller or re-encoded copy of an upload, such as a thumbnail or a 720p video, made for faster loading. A rendition profile lists the renditions a library's uploads get; a library picks its profile when it is created."
            )}
            {gettext(
              "A new install starts with 8 standard renditions: 4 image sizes (thumbnail, small, medium, large) and 4 video ones (360p, 720p, 1080p, video thumbnail)."
            )}
          </p>

          <form
            :if={@creating}
            id={"#{@id}-new"}
            phx-submit="create_set"
            phx-target={@myself}
            class="flex flex-wrap items-center gap-2 mt-4"
          >
            <input
              type="text"
              name="name"
              id={"#{@id}-new-name"}
              class="input input-sm w-64"
              placeholder={gettext("Rendition profile name")}
              maxlength="255"
              required
              autofocus
            />
            <button type="submit" class="btn btn-sm btn-primary">{gettext("Create")}</button>
            <button type="button" class="btn btn-sm btn-ghost" phx-click="cancel" phx-target={@myself}>
              {gettext("Cancel")}
            </button>
          </form>
        </div>
      </div>

      <%!-- Rendition profiles: one tab each --%>
      <div class="mb-6">
        <div role="tablist" class="tabs tabs-box inline-flex flex-wrap">
          <.link
            :for={set <- @sets}
            patch={set_path(set)}
            role="tab"
            class={["tab", set.uuid == @set.uuid && "tab-active"]}
          >
            {set.name}
          </.link>
        </div>
      </div>

      <%!-- The set itself --%>
      <div class="card bg-base-100 shadow-sm mb-6">
        <div class="card-body">
          <div :if={@missing_slots != []} id={"#{@id}-missing-slots"} class="alert alert-warning">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <span>
              {gettext(
                "This profile is missing standard renditions: %{names}. Until they are added, those are served as the nearest smaller rendition or a placeholder.",
                names: Enum.join(@missing_slots, ", ")
              )}
            </span>
          </div>
          <.form
            for={@set_form}
            id={"#{@id}-set-form-#{@set.uuid}"}
            phx-submit="save_set"
            phx-target={@myself}
            class="grid grid-cols-1 md:grid-cols-2 gap-4"
          >
            <.input field={@set_form[:name]} label={gettext("Name")} required />
            <div class="flex flex-col gap-2 pt-6">
              <.checkbox
                field={@set_form[:generate_variants]}
                label={gettext("Create renditions automatically after an upload")}
              />
              <.checkbox
                :if={not @set.is_default}
                field={@set_form[:selectable]}
                label={gettext("Users may choose it for their own libraries")}
              />
            </div>
            <div class="md:col-span-2 flex flex-wrap items-center gap-2">
              <button type="submit" class="btn btn-primary btn-sm">{gettext("Save")}</button>
              <button
                type="button"
                phx-click="check_set"
                phx-target={@myself}
                data-confirm={
                  gettext(
                    "Check every file of this rendition profile now? Renditions a file is missing are made in the background."
                  )
                }
                class="btn btn-outline btn-sm"
              >
                <.icon name="hero-arrow-path" class="w-4 h-4" /> {gettext("Check every file")}
              </button>
              <span class="text-sm text-base-content/60">
                {ngettext(
                  "Used by %{count} library.",
                  "Used by %{count} libraries.",
                  @set_libraries
                )}
                <%= if @set.is_default do %>
                  {gettext("Every library without its own profile uses this one.")}
                <% end %>
              </span>
              <button
                :if={not @set.is_default}
                type="button"
                phx-click="delete_set"
                phx-target={@myself}
                disabled={@set_libraries > 0}
                data-confirm={gettext("Delete this rendition profile and its renditions?")}
                class="btn btn-outline btn-error btn-sm ml-auto"
              >
                <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Delete profile")}
              </button>
            </div>
          </.form>
        </div>
      </div>

      <%!-- Page-level actions. Deliberately NOT in the image table's
         `:toolbar_actions` slot: that table only renders when dimensions exist,
         and restoring the defaults is exactly what an empty list needs. --%>
      <div :if={@set.is_default} class="flex flex-wrap items-center gap-2 justify-end mb-4">
        <button
          phx-click="reset_dimensions_to_defaults"
          phx-target={@myself}
          data-confirm={
            gettext(
              "Are you sure? This will delete all current renditions and restore the 8 standard ones. This action cannot be undone."
            )
          }
          class="btn btn-outline btn-error btn-sm"
        >
          <.icon name="hero-arrow-path" class="w-4 h-4 mr-1" /> {gettext("Reset to Defaults")}
        </button>
      </div>

      <%!-- Dimensions List --%>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <%= if length(@dimensions) == 0 do %>
            <.empty_state
              icon="hero-photo"
              title={gettext("No renditions yet")}
              description={gettext("Add a rendition to start making smaller copies of uploads.")}
            >
              <div class="flex justify-center gap-4">
                <.link
                  navigate={new_dimension_path(@set, "image")}
                  class="btn btn-primary"
                >
                  <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext("Add image rendition")}
                </.link>
                <.link
                  navigate={new_dimension_path(@set, "video")}
                  class="btn btn-outline"
                >
                  <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext("Add video rendition")}
                </.link>
              </div>
            </.empty_state>
          <% else %>
            <%!-- Image Dimensions --%>
            <div class="mb-8">
              <.section_header icon="hero-photo" title={gettext("Image renditions")} class="mb-4">
                <:actions>
                  <.link
                    navigate={new_dimension_path(@set, "image")}
                    class="btn btn-primary btn-sm"
                  >
                    <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext("Add image rendition")}
                  </.link>
                </:actions>
              </.section_header>

              <% image_dims =
                Enum.filter(@dimensions, &(&1.applies_to in ["image", "both"])) %>

              <.table_default
                id={"#{@id}-image-table"}
                variant="zebra"
                toggleable={true}
                items={image_dims}
                card_title={fn d -> d.name end}
                card_fields={
                  fn d ->
                    [
                      %{
                        label: gettext("Dimensions"),
                        value: size_line(d, :image)
                      },
                      %{
                        label: gettext("Mode"),
                        value:
                          if(d.maintain_aspect_ratio,
                            do: gettext("Keeps proportions"),
                            else: gettext("Fixed size")
                          )
                      },
                      %{label: gettext("Quality"), value: "#{d.quality}%"},
                      %{
                        label: gettext("Format"),
                        value:
                          if(d.format, do: String.upcase(d.format), else: gettext("Original")) <>
                            if((d.alternative_formats || []) != [],
                              do:
                                " + " <>
                                  Enum.map_join(d.alternative_formats, ", ", &String.upcase/1),
                              else: ""
                            )
                      },
                      %{
                        label: gettext("Status"),
                        value: if(d.enabled, do: gettext("Enabled"), else: gettext("Disabled"))
                      }
                    ]
                  end
                }
              >
                <.table_default_header>
                  <.table_default_row>
                    <.table_default_header_cell>{gettext("Name")}</.table_default_header_cell>
                    <.table_default_header_cell>{gettext("Dimensions")}</.table_default_header_cell>
                    <.table_default_header_cell>{gettext("Mode")}</.table_default_header_cell>
                    <.table_default_header_cell>{gettext("Quality")}</.table_default_header_cell>
                    <.table_default_header_cell>{gettext("Format")}</.table_default_header_cell>
                    <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
                    <.table_default_header_cell>{gettext("Actions")}</.table_default_header_cell>
                  </.table_default_row>
                </.table_default_header>
                <.table_default_body>
                  <%= for dimension <- image_dims do %>
                    <.table_default_row>
                      <.table_default_cell>
                        <div class="font-bold">{dimension.name}</div>
                        <span
                          :if={Dimension.standard_slot?(dimension)}
                          class="badge badge-ghost badge-xs"
                        >
                          {gettext("standard")}
                        </span>
                      </.table_default_cell>
                      <.table_default_cell>
                        <% {size, note} = size_text(dimension, :image) %>
                        <div class="font-mono text-sm">{size}</div>
                        <div :if={note} class="text-xs text-base-content/60">{note}</div>
                      </.table_default_cell>
                      <.table_default_cell>
                        <%= if dimension.maintain_aspect_ratio do %>
                          <span class="badge badge-info badge-sm h-auto">
                            {gettext("Keeps proportions")}
                          </span>
                        <% else %>
                          <span class="badge badge-secondary badge-sm h-auto">
                            {gettext("Fixed size")}
                          </span>
                        <% end %>
                      </.table_default_cell>
                      <.table_default_cell>
                        <span class="text-sm">{dimension.quality}%</span>
                      </.table_default_cell>
                      <.table_default_cell>
                        <%= if dimension.format do %>
                          <span class="text-sm font-mono uppercase">{dimension.format}</span>
                        <% else %>
                          <span class="text-sm text-base-content/60">{gettext("Original")}</span>
                        <% end %>
                        <%= if (dimension.alternative_formats || []) != [] do %>
                          <%= for fmt <- dimension.alternative_formats do %>
                            <span class="badge badge-outline badge-xs font-mono uppercase">
                              +{fmt}
                            </span>
                          <% end %>
                        <% end %>
                      </.table_default_cell>
                      <.table_default_cell>
                        <%= if dimension.enabled do %>
                          <span class="badge badge-success badge-sm h-auto">
                            {gettext("Enabled")}
                          </span>
                        <% else %>
                          <span class="badge badge-error badge-sm h-auto">
                            {gettext("Disabled")}
                          </span>
                        <% end %>
                      </.table_default_cell>
                      <.table_default_cell>
                        <.table_row_menu
                          id={"img-dim-menu-#{dimension.uuid}"}
                          label={gettext("Rendition actions")}
                        >
                          <.table_row_menu_link
                            navigate={
                              PhoenixKit.Utils.Routes.path(
                                "/admin/settings/media/renditions/#{dimension.uuid}/edit"
                              )
                            }
                            icon="hero-pencil"
                            label={gettext("Edit")}
                          />
                          <.table_row_menu_button
                            phx-click="toggle_dimension"
                            phx-target={@myself}
                            phx-debounce="1000"
                            phx-value-id={dimension.uuid}
                            icon={if dimension.enabled, do: "hero-eye-slash", else: "hero-eye"}
                            label={
                              if dimension.enabled, do: gettext("Disable"), else: gettext("Enable")
                            }
                          />
                          <.table_row_menu_button
                            :if={not Dimension.standard_slot?(dimension)}
                            phx-click="delete_dimension"
                            phx-target={@myself}
                            phx-debounce="1000"
                            phx-value-id={dimension.uuid}
                            data-confirm={gettext("Are you sure you want to delete this rendition?")}
                            icon="hero-trash"
                            label={gettext("Delete")}
                            class="text-error"
                          />
                        </.table_row_menu>
                      </.table_default_cell>
                    </.table_default_row>
                  <% end %>
                </.table_default_body>

                <:card_actions :let={dimension}>
                  <.link
                    navigate={
                      PhoenixKit.Utils.Routes.path(
                        "/admin/settings/media/renditions/#{dimension.uuid}/edit"
                      )
                    }
                    class="btn btn-xs btn-outline btn-info"
                  >
                    <.icon name="hero-pencil" class="w-3 h-3" /> {gettext("Edit")}
                  </.link>
                  <button
                    phx-click="toggle_dimension"
                    phx-target={@myself}
                    phx-debounce="1000"
                    phx-value-id={dimension.uuid}
                    class="btn btn-xs btn-outline"
                  >
                    {if dimension.enabled, do: gettext("Disable"), else: gettext("Enable")}
                  </button>
                  <button
                    :if={not Dimension.standard_slot?(dimension)}
                    phx-click="delete_dimension"
                    phx-target={@myself}
                    phx-debounce="1000"
                    phx-value-id={dimension.uuid}
                    data-confirm={gettext("Are you sure you want to delete this rendition?")}
                    class="btn btn-xs btn-outline btn-error"
                  >
                    <.icon name="hero-trash" class="w-3 h-3" /> {gettext("Delete")}
                  </button>
                </:card_actions>
              </.table_default>

              <p id={"#{@id}-image-legend"} class="mt-3 text-xs text-base-content/60">
                <strong>{gettext("Keeps proportions")}:</strong>
                {gettext("the width is set and the height follows each image.")}
                <strong>{gettext("Fixed size")}:</strong>
                {gettext("the image is scaled to fill the box and the excess is cropped.")}
                {gettext(
                  "A rendition never enlarges an image: one smaller than the size stays as it is."
                )}
              </p>
            </div>

            <%!-- Video Dimensions --%>
            <div>
              <.section_header
                icon="hero-video-camera"
                title={gettext("Video renditions")}
                class="mb-4"
              >
                <:actions>
                  <.link
                    navigate={new_dimension_path(@set, "video")}
                    class="btn btn-primary btn-sm"
                  >
                    <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext("Add video rendition")}
                  </.link>
                </:actions>
              </.section_header>

              <% video_dims =
                Enum.filter(@dimensions, &(&1.applies_to in ["video", "both"])) %>

              <.table_default
                id={"#{@id}-video-table"}
                variant="zebra"
                toggleable={true}
                items={video_dims}
                card_title={fn d -> d.name end}
                card_fields={
                  fn d ->
                    [
                      %{
                        label: gettext("Resolution"),
                        value: size_line(d, :video)
                      },
                      %{
                        label: gettext("Mode"),
                        value:
                          if(d.maintain_aspect_ratio,
                            do: gettext("Keeps proportions"),
                            else: gettext("Fixed size")
                          )
                      },
                      %{label: gettext("Quality (CRF)"), value: "#{d.quality}"},
                      %{
                        label: gettext("Codec"),
                        value: if(d.format, do: String.upcase(d.format), else: gettext("Original"))
                      },
                      %{
                        label: gettext("Status"),
                        value: if(d.enabled, do: gettext("Enabled"), else: gettext("Disabled"))
                      }
                    ]
                  end
                }
              >
                <.table_default_header>
                  <.table_default_row>
                    <.table_default_header_cell>{gettext("Name")}</.table_default_header_cell>
                    <.table_default_header_cell>
                      {gettext("Resolution")}
                    </.table_default_header_cell>
                    <.table_default_header_cell>{gettext("Mode")}</.table_default_header_cell>
                    <.table_default_header_cell>
                      {gettext("Quality (CRF)")}
                    </.table_default_header_cell>
                    <.table_default_header_cell>{gettext("Codec")}</.table_default_header_cell>
                    <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
                    <.table_default_header_cell>{gettext("Actions")}</.table_default_header_cell>
                  </.table_default_row>
                </.table_default_header>
                <.table_default_body>
                  <%= for dimension <- video_dims do %>
                    <.table_default_row>
                      <.table_default_cell>
                        <div class="font-bold">{dimension.name}</div>
                        <span
                          :if={Dimension.standard_slot?(dimension)}
                          class="badge badge-ghost badge-xs"
                        >
                          {gettext("standard")}
                        </span>
                      </.table_default_cell>
                      <.table_default_cell>
                        <% {size, note} = size_text(dimension, :video) %>
                        <div class="font-mono text-sm">{size}</div>
                        <div :if={note} class="text-xs text-base-content/60">{note}</div>
                      </.table_default_cell>
                      <.table_default_cell>
                        <%= if dimension.maintain_aspect_ratio do %>
                          <span class="badge badge-info badge-sm h-auto">
                            {gettext("Keeps proportions")}
                          </span>
                        <% else %>
                          <span class="badge badge-secondary badge-sm h-auto">
                            {gettext("Fixed size")}
                          </span>
                        <% end %>
                      </.table_default_cell>
                      <.table_default_cell>
                        <span class="text-sm">{dimension.quality}</span>
                      </.table_default_cell>
                      <.table_default_cell>
                        <%= if dimension.format do %>
                          <span class="text-sm font-mono uppercase">{dimension.format}</span>
                        <% else %>
                          <span class="text-sm text-base-content/60">{gettext("Original")}</span>
                        <% end %>
                        <%= if (dimension.alternative_formats || []) != [] do %>
                          <%= for fmt <- dimension.alternative_formats do %>
                            <span class="badge badge-outline badge-xs font-mono uppercase">
                              +{fmt}
                            </span>
                          <% end %>
                        <% end %>
                      </.table_default_cell>
                      <.table_default_cell>
                        <%= if dimension.enabled do %>
                          <span class="badge badge-success badge-sm h-auto">
                            {gettext("Enabled")}
                          </span>
                        <% else %>
                          <span class="badge badge-error badge-sm h-auto">
                            {gettext("Disabled")}
                          </span>
                        <% end %>
                      </.table_default_cell>
                      <.table_default_cell>
                        <.table_row_menu
                          id={"vid-dim-menu-#{dimension.uuid}"}
                          label={gettext("Rendition actions")}
                        >
                          <.table_row_menu_link
                            navigate={
                              PhoenixKit.Utils.Routes.path(
                                "/admin/settings/media/renditions/#{dimension.uuid}/edit"
                              )
                            }
                            icon="hero-pencil"
                            label={gettext("Edit")}
                          />
                          <.table_row_menu_button
                            phx-click="toggle_dimension"
                            phx-target={@myself}
                            phx-debounce="1000"
                            phx-value-id={dimension.uuid}
                            icon={if dimension.enabled, do: "hero-eye-slash", else: "hero-eye"}
                            label={
                              if dimension.enabled, do: gettext("Disable"), else: gettext("Enable")
                            }
                          />
                          <.table_row_menu_button
                            :if={not Dimension.standard_slot?(dimension)}
                            phx-click="delete_dimension"
                            phx-target={@myself}
                            phx-debounce="1000"
                            phx-value-id={dimension.uuid}
                            data-confirm={gettext("Are you sure you want to delete this rendition?")}
                            icon="hero-trash"
                            label={gettext("Delete")}
                            class="text-error"
                          />
                        </.table_row_menu>
                      </.table_default_cell>
                    </.table_default_row>
                  <% end %>
                </.table_default_body>

                <:card_actions :let={dimension}>
                  <.link
                    navigate={
                      PhoenixKit.Utils.Routes.path(
                        "/admin/settings/media/renditions/#{dimension.uuid}/edit"
                      )
                    }
                    class="btn btn-xs btn-outline btn-info"
                  >
                    <.icon name="hero-pencil" class="w-3 h-3" /> {gettext("Edit")}
                  </.link>
                  <button
                    phx-click="toggle_dimension"
                    phx-target={@myself}
                    phx-debounce="1000"
                    phx-value-id={dimension.uuid}
                    class="btn btn-xs btn-outline"
                  >
                    {if dimension.enabled, do: gettext("Disable"), else: gettext("Enable")}
                  </button>
                  <button
                    :if={not Dimension.standard_slot?(dimension)}
                    phx-click="delete_dimension"
                    phx-target={@myself}
                    phx-debounce="1000"
                    phx-value-id={dimension.uuid}
                    data-confirm={gettext("Are you sure you want to delete this rendition?")}
                    class="btn btn-xs btn-outline btn-error"
                  >
                    <.icon name="hero-trash" class="w-3 h-3" /> {gettext("Delete")}
                  </button>
                </:card_actions>
              </.table_default>

              <p id={"#{@id}-video-legend"} class="mt-3 text-xs text-base-content/60">
                <strong>{gettext("Keeps proportions")}:</strong>
                {gettext("the width is set and the height follows each video.")}
                <strong>{gettext("Fixed size")}:</strong>
                {gettext(
                  "the video is scaled to fit inside the box, keeping its shape: nothing is cropped or stretched."
                )}
                {gettext(
                  "A rendition never enlarges a video: one smaller than the size stays as it is."
                )}
                {gettext("Quality is the CRF number: lower means better quality and a bigger file.")}
              </p>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Help Section --%>
      <div class="alert mt-6">
        <.icon name="hero-light-bulb" class="w-5 h-5" />
        <div>
          <h3 class="font-bold">{gettext("Quality and format")}</h3>
          <p class="text-sm">
            <strong>{gettext("Quality Settings:")}</strong>
            {gettext("Images use 1-100 scale (compression quality)")}<br />
            <strong>{gettext("Video Settings:")}</strong>
            {gettext("Videos use CRF 0-51 scale (lower = higher quality)")}<br />
            <strong>{gettext("Format Override:")}</strong>
            {gettext("Leave empty to preserve original format, or specify jpg/png/webp/mp4")}
          </p>
        </div>
      </div>
    </div>
    """
  end
end
