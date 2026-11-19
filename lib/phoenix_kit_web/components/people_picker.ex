defmodule PhoenixKitWeb.Components.PeoplePicker do
  @moduledoc """
  Pick people: a search over whatever a `PeoplePicker.Source` offers (core's
  accounts by default; a module's people, teams and departments), the choice
  as chips with faces, the viewer's Recent picks one press away and an
  "Add me" button. Lifted out of `phoenix_kit_projects`' assignee picker
  (the boss, 2026-11-18: "this component should be in core").

  A LiveComponent: the lists, the search and the Recent chips are its own;
  the CHOICE is the parent's. Every change is sent to the parent LiveView as

      {PhoenixKitWeb.Components.PeoplePicker, id, {:changed, keys}}

  with the whole new list (`[{kind, uuid}]`, in the order they were added);
  the parent stores it and renders the picker again with `selected={keys}`.
  The picker shows a change at once; a parent that refuses one must hand
  the picker its list back (assign it again), or the chips — and the hidden
  inputs of a surrounding form — keep the refused pick.
  The parent is also the authority on who may change it: a crafted event
  reaches `handle_info/2` like a real one, so a write re-checks there. Picks
  are looked up again in the source (`describe/2`), so a forged key picks
  nothing.

      <.live_component
        module={PhoenixKitWeb.Components.PeoplePicker}
        id="task-assignees"
        selected={@assignees}
        name="task[assignees][]"
        label={gettext("Assignees")}
      />

      def handle_info({PhoenixKitWeb.Components.PeoplePicker, "task-assignees", {:changed, keys}}, socket),
        do: {:noreply, assign(socket, :assignees, keys)}

  ## Attributes

    * `id` (required) — page-unique; every DOM id inside derives from it.
    * `selected` — the chosen keys, `[{kind, uuid}]` (default `[]`).
    * `source` — a `PeoplePicker.Source` module (default `UserSource`).
    * `source_opts` — a map handed to every source callback as `ctx`, with
      `:viewer_uuid` and `:locale` added.
    * `viewer_uuid` — who is picking (Recent, "Add me"); default the
      `phoenix_kit_current_user`'s, else nil.
    * `name` — when set, the choice is also posted with a surrounding form:
      one hidden input `"kind:uuid"` per key, after an empty one so a
      cleared list still posts.
    * `can_edit` — false shows the chips alone (no search, no ×).
    * `max` — `1` makes a pick replace the choice; nil (default) adds.
    * `tags` — `%{key => [tag]}`: small labels on a chip ("You", "Project
      owner", "Not on this project"); a tag is a string or `%{label:,
      tone:}`, tone `:neutral` (default), `:info`, `:success`, `:warning`.
    * `label`, `placeholder`, `me_label` ("Add me"; nil hides the button),
      `class`.

  The search field belongs to no form (its `form` attribute names none), so
  typing in it never sends the surrounding form's `phx-change` and Enter
  never submits it. The list opens under the field, in the flow — a popup's
  scroll area cannot clip it — and keeps its place when a person is added.
  """

  use PhoenixKitWeb, :live_component

  alias PhoenixKitWeb.Components.PeoplePicker.UserSource

  @home_size 5
  @page_size 20
  @recent_size 8

  # ── Lifecycle ──────────────────────────────────────────────────────

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       open?: false,
       view: :home,
       home: nil,
       cursor: nil,
       listed: %{},
       rows: %{},
       recent: nil,
       confirm: nil,
       notice: nil,
       query: ""
     )
     |> stream_configure(:options, dom_id: &option_dom_id/1)
     |> stream(:options, [])}
  end

  @impl true
  def update(assigns, socket) do
    was_selected = socket.assigns[:selected]
    was_viewer = socket.assigns[:viewer_uuid]

    socket =
      socket
      |> assign(Map.drop(assigns, [:flash, :viewer_uuid]))
      |> assign_new(:selected, fn -> [] end)
      |> assign_new(:source, fn -> UserSource end)
      |> assign_new(:source_opts, fn -> %{} end)
      |> assign_new(:name, fn -> nil end)
      |> assign_new(:can_edit, fn -> true end)
      |> assign_new(:max, fn -> nil end)
      |> assign_new(:tags, fn -> %{} end)
      |> assign_new(:label, fn -> nil end)
      |> assign_new(:placeholder, fn -> nil end)
      |> assign_new(:me_label, fn -> gettext("Add me") end)
      |> assign_new(:class, fn -> nil end)
      |> assign(:viewer_uuid, assigns[:viewer_uuid] || viewer_from(assigns) || was_viewer)

    selected = normalize_keys(socket.assigns.selected)

    socket =
      socket
      |> assign(:selected, selected)
      # Another viewer: their own Recent and "Add me".
      |> then(&if(&1.assigns.viewer_uuid != was_viewer, do: assign(&1, :recent, nil), else: &1))
      # The parent's list differs from what was drawn (it refused a change,
      # or changed it itself): the chips are looked up again and the ticks of
      # the listed rows follow.
      |> then(fn s ->
        if is_list(was_selected) and was_selected != selected do
          s
          |> assign(:rows, Map.take(s.assigns.rows, selected))
          |> refresh_rows((selected -- was_selected) ++ (was_selected -- selected))
        else
          s
        end
      end)

    {:ok,
     socket
     |> describe_selected()
     |> load_recent()
     |> assign_me()}
  end

  # The "Add me" key, only when the source can describe it (an inactive or
  # service account has no button that would do nothing).
  defp assign_me(socket) do
    me =
      with true <- socket.assigns.can_edit and is_binary(socket.assigns.me_label),
           {_, _} = key <- me_key(socket),
           %{} <- safe(fn -> socket.assigns.source.describe(key, ctx(socket)) end, nil) do
        key
      else
        _ -> nil
      end

    assign(socket, :me_key, me)
  end

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("open", _params, socket) do
    if socket.assigns.can_edit,
      do: {:noreply, socket |> assign(:open?, true) |> load_home()},
      else: {:noreply, socket}
  end

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, :open?, false)}

  def handle_event("query", %{"value" => value}, socket) when is_binary(value) do
    if socket.assigns.can_edit do
      text = value |> String.trim() |> String.slice(0, 100)
      socket = assign(socket, open?: true, query: text)

      if text == "",
        do: {:noreply, socket |> load_home() |> show(:home)},
        else: {:noreply, show(socket, {:search, text})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("query", _params, socket), do: {:noreply, socket}

  def handle_event("browse", %{"group" => group}, socket) when is_binary(group) do
    groups = socket |> ctx() |> then(&safe(fn -> socket.assigns.source.groups(&1) end, []))

    if socket.assigns.can_edit and Enum.any?(groups, &(&1.key == group)),
      do: {:noreply, show(socket, {:group, group})},
      else: {:noreply, socket}
  end

  def handle_event("back", _params, socket), do: {:noreply, show(socket, :home)}

  def handle_event("more", _params, socket) do
    case {socket.assigns.view, socket.assigns.cursor} do
      {{_, _} = view, cursor} when not is_nil(cursor) ->
        {:noreply, load_page(socket, view, cursor)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle", %{"kind" => kind, "uuid" => uuid}, socket)
      when is_binary(kind) and is_binary(uuid) do
    key = {kind, uuid}

    cond do
      not socket.assigns.can_edit ->
        {:noreply, socket}

      key in socket.assigns.selected ->
        {:noreply, change(socket, socket.assigns.selected -- [key])}

      true ->
        {:noreply, pick(socket, key)}
    end
  end

  def handle_event("remove", %{"kind" => kind, "uuid" => uuid}, socket)
      when is_binary(kind) and is_binary(uuid) do
    key = {kind, uuid}

    if socket.assigns.can_edit and key in socket.assigns.selected,
      do: {:noreply, change(socket, socket.assigns.selected -- [key])},
      else: {:noreply, socket}
  end

  def handle_event("recent", %{"kind" => kind, "uuid" => uuid}, socket) do
    offered? = Enum.any?(socket.assigns.recent || [], &(&1.kind == kind and &1.uuid == uuid))

    if socket.assigns.can_edit and offered?,
      do: {:noreply, pick(socket, {kind, uuid})},
      else: {:noreply, socket}
  end

  def handle_event("me", _params, socket) do
    case socket.assigns.can_edit && me_key(socket) do
      {_, _} = key -> {:noreply, pick(socket, key)}
      _ -> {:noreply, socket}
    end
  end

  # The Yes of a pick the source asked about: the held key, asked again.
  def handle_event("confirm", _params, socket) do
    case socket.assigns.confirm do
      %{key: key} when socket.assigns.can_edit ->
        socket = assign(socket, :confirm, nil)

        case safe(fn -> socket.assigns.source.confirm(key, ctx(socket)) end, {:error, nil}) do
          {:ok, {_, _} = picked} -> {:noreply, add_described(socket, picked)}
          {:error, message} -> {:noreply, assign(socket, :notice, message)}
          _ -> {:noreply, socket}
        end

      _ ->
        {:noreply, assign(socket, :confirm, nil)}
    end
  end

  def handle_event("cancel_confirm", _params, socket),
    do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Choosing ───────────────────────────────────────────────────────

  # A pick names a key the source can describe; the source may turn it into
  # another key, ask first, or refuse with a line.
  defp pick(socket, key) do
    source = socket.assigns.source
    ctx = ctx(socket)

    cond do
      is_nil(safe(fn -> source.describe(key, ctx) end, nil)) ->
        socket

      function_exported?(source, :pick, 2) ->
        case safe(fn -> source.pick(key, ctx) end, {:error, nil}) do
          {:ok, {_, _} = picked} ->
            add_described(socket, picked)

          {:confirm, %{} = prompt} ->
            assign(socket, confirm: Map.put(prompt, :key, key), notice: nil)

          {:error, message} ->
            assign(socket, :notice, message)

          _ ->
            socket
        end

      true ->
        add(socket, key)
    end
  end

  # A key a source handed back (`pick/2`, `confirm/2`) is looked up like a
  # picked one: what cannot be described is not added.
  defp add_described(socket, key) do
    case safe(fn -> socket.assigns.source.describe(key, ctx(socket)) end, nil) do
      nil -> socket
      row -> socket |> assign(:rows, Map.put(socket.assigns.rows, key, row)) |> add(key)
    end
  end

  defp add(socket, key) do
    was = socket.assigns.selected

    keys =
      cond do
        key in was -> was
        socket.assigns.max == 1 -> [key]
        is_integer(socket.assigns.max) and length(was) >= socket.assigns.max -> was
        true -> was ++ [key]
      end

    # Nothing changed (already chosen, or the list is full): no message, and
    # the pick is not remembered as one.
    if keys == was do
      socket
    else
      source = socket.assigns.source

      if function_exported?(source, :remember, 2),
        do: safe(fn -> source.remember(key, ctx(socket)) end, :ok)

      socket
      |> assign(:notice, nil)
      |> change(keys)
      |> assign(:recent, nil)
      |> load_recent()
    end
  end

  # The new list: drawn at once (the parent's answer redraws it again,
  # the same), and sent to the parent.
  defp change(socket, keys) do
    was = socket.assigns.selected
    send(self(), {__MODULE__, socket.assigns.id, {:changed, keys}})

    socket
    |> assign(:selected, keys)
    |> describe_selected()
    |> refresh_rows((keys -- was) ++ (was -- keys))
  end

  # The listed rows of these keys, inserted again so their tick follows (a
  # stream keeps no assigns of its own). In place: the list does not move.
  defp refresh_rows(socket, keys) do
    Enum.reduce(keys, socket, fn key, acc ->
      case Map.get(acc.assigns.listed, key) do
        nil -> acc
        row -> stream_insert(acc, :options, row)
      end
    end)
  end

  # ── Lists ──────────────────────────────────────────────────────────

  defp show(socket, :home) do
    socket
    |> assign(view: :home, cursor: nil, listed: %{})
    |> stream(:options, [], reset: true)
  end

  defp show(socket, view) do
    socket
    |> assign(view: view, cursor: nil, listed: %{})
    |> stream(:options, [], reset: true)
    |> load_page(view, nil)
  end

  defp load_page(socket, view, cursor) do
    {rows, next} =
      safe(fn -> socket.assigns.source.page(view, cursor, @page_size, ctx(socket)) end, {[], nil})

    rows = Enum.filter(rows, &valid_row?/1)
    listed = Enum.reduce(rows, socket.assigns.listed, &Map.put(&2, {&1.kind, &1.uuid}, &1))

    socket
    |> assign(cursor: next, listed: listed)
    |> stream(:options, rows)
  end

  # The opening lists, read once per picker (when it first opens).
  defp load_home(%{assigns: %{home: home}} = socket) when is_list(home), do: socket

  defp load_home(socket) do
    source = socket.assigns.source
    ctx = ctx(socket)

    home =
      for group <- safe(fn -> source.groups(ctx) end, []) do
        {rows, next} =
          safe(fn -> source.page({:group, group.key}, nil, @home_size, ctx) end, {[], nil})

        %{
          key: group.key,
          label: group.label,
          rows: Enum.filter(rows, &valid_row?/1),
          more?: not is_nil(next)
        }
      end

    assign(socket, :home, home)
  end

  defp load_recent(%{assigns: %{recent: recent}} = socket) when is_list(recent), do: socket

  defp load_recent(socket) do
    source = socket.assigns.source

    recent =
      if socket.assigns.can_edit and function_exported?(source, :recent, 2),
        do: safe(fn -> source.recent(@recent_size, ctx(socket)) end, []),
        else: []

    assign(socket, :recent, Enum.filter(recent, &valid_row?/1))
  end

  # A chip's row for every chosen key not described yet.
  defp describe_selected(socket) do
    source = socket.assigns.source
    ctx = ctx(socket)

    rows =
      Enum.reduce(socket.assigns.selected, socket.assigns.rows, fn key, acc ->
        case Map.get(acc, key) do
          nil -> Map.put(acc, key, safe(fn -> source.describe(key, ctx) end, nil))
          _row -> acc
        end
      end)

    assign(socket, :rows, rows)
  end

  defp me_key(socket) do
    source = socket.assigns.source

    if function_exported?(source, :me, 1),
      do: safe(fn -> source.me(ctx(socket)) end, nil),
      else: nil
  end

  defp ctx(socket) do
    socket.assigns.source_opts
    |> Map.new()
    |> Map.put(:viewer_uuid, socket.assigns.viewer_uuid)
    |> Map.put(:locale, Gettext.get_locale(PhoenixKitWeb.Gettext))
  end

  defp viewer_from(assigns) do
    case assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} when is_binary(uuid) -> uuid
      _ -> nil
    end
  end

  defp normalize_keys(keys) when is_list(keys) do
    keys
    |> Enum.flat_map(fn
      {kind, uuid} when is_binary(kind) and is_binary(uuid) -> [{kind, uuid}]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp normalize_keys(_), do: []

  defp valid_row?(%{kind: kind, uuid: uuid, label: label})
       when is_binary(kind) and is_binary(uuid) and is_binary(label),
       do: true

  defp valid_row?(_), do: false

  defp safe(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end

  # The key encoded, so two keys can never share a DOM id ("team-a" + "b"
  # and "team" + "a-b" would, joined with a dash).
  defp option_dom_id(%{kind: kind, uuid: uuid}),
    do: "opt-" <> Base.url_encode64(kind <> <<0>> <> uuid, padding: false)

  # ── Rendering ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        recent_shown: Enum.reject(assigns.recent || [], &({&1.kind, &1.uuid} in assigns.selected))
      )

    ~H"""
    <div id={@id} class={["flex flex-col gap-2", @class]} data-count={length(@selected)}>
      <input :if={@name} type="hidden" name={@name} value="" />
      <input
        :for={{kind, uuid} <- (@name && @selected) || []}
        type="hidden"
        name={@name}
        value={"#{kind}:#{uuid}"}
      />

      <div :if={@label || @me_key} class="flex items-center justify-between gap-2">
        <label :if={@label} for={"#{@id}-q"} class="text-sm font-semibold">{@label}</label>
        <button
          :if={@me_key && @me_key not in @selected}
          type="button"
          id={"#{@id}-me"}
          phx-click="me"
          phx-target={@myself}
          class="btn btn-xs btn-outline gap-1 ml-auto"
        >
          <.icon name="hero-user-plus" class="w-3.5 h-3.5" /> {@me_label}
        </button>
      </div>

      <%!-- The choice: a card each, in the order added. --%>
      <div :if={@selected != []} id={"#{@id}-chips"} class="flex flex-wrap gap-2">
        <.chip
          :for={key <- @selected}
          id={@id}
          key={key}
          row={Map.get(@rows, key)}
          tags={Map.get(@tags, key, [])}
          can_edit={@can_edit}
          myself={@myself}
        />
      </div>
      <p :if={@selected == [] and not @can_edit} class="text-sm text-base-content/60">
        {gettext("Nobody chosen")}
      </p>

      <p :if={@notice} id={"#{@id}-notice"} class="text-xs text-warning">{@notice}</p>

      <%!-- A pick the source asks about first: asked here, in the flow
           (a dialog in a dialog is clipped by the outer one). --%>
      <div
        :if={@confirm}
        id={"#{@id}-confirm"}
        class="rounded-box border border-warning/40 bg-warning/5 p-3 flex flex-col gap-2"
        role="alertdialog"
        aria-labelledby={"#{@id}-confirm-title"}
      >
        <p id={"#{@id}-confirm-title"} class="font-semibold text-sm">{@confirm.title}</p>
        <p class="text-sm text-base-content/70">{@confirm.text}</p>
        <div class="flex justify-end gap-2">
          <button
            type="button"
            phx-click="cancel_confirm"
            phx-target={@myself}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Cancel")}
          </button>
          <button
            type="button"
            id={"#{@id}-confirm-yes"}
            phx-click="confirm"
            phx-target={@myself}
            class="btn btn-primary btn-sm"
          >
            {@confirm.confirm}
          </button>
        </div>
      </div>

      <div
        :if={@can_edit}
        id={"#{@id}-search"}
        phx-click-away={@open? && "close"}
        phx-target={@myself}
      >
        <label class="input input-sm w-full flex items-center gap-2">
          <.icon name="hero-magnifying-glass" class="w-4 h-4 opacity-60" />
          <%!-- `form` names no form: typing here is not the surrounding
               form's change, and Enter submits nothing. --%>
          <input
            id={"#{@id}-q"}
            type="search"
            form={"#{@id}-no-form"}
            value={@query}
            phx-keyup="query"
            phx-debounce="250"
            phx-focus="open"
            phx-target={@myself}
            autocomplete="off"
            role="combobox"
            aria-expanded={to_string(@open?)}
            aria-controls={"#{@id}-list"}
            placeholder={@placeholder || gettext("Search by name or email")}
            class="grow"
          />
        </label>

        <%!-- Hidden when closed, never removed: the list, its page and its
             scroll stay where they were. --%>
        <div
          id={"#{@id}-list"}
          role="listbox"
          aria-multiselectable={to_string(@max != 1)}
          class={[
            "mt-1 max-h-72 overflow-y-auto overscroll-contain p-1 rounded-box border border-base-300 bg-base-100 shadow-sm",
            not @open? && "hidden"
          ]}
        >
          <div :if={@view == :home} id={"#{@id}-home"}>
            <section
              :for={group <- @home || []}
              :if={group.rows != []}
              id={"#{@id}-group-#{group.key}"}
              class="mb-1"
            >
              <h4 class="px-2 pt-1 pb-0.5 text-xs font-semibold uppercase tracking-wide text-base-content/60">
                {group.label}
              </h4>
              <ul class="flex flex-col">
                <li :for={row <- group.rows} id={"#{@id}-home-#{row.kind}-#{row.uuid}"}>
                  <.option row={row} selected={@selected} myself={@myself} />
                </li>
              </ul>
              <button
                :if={group.more?}
                type="button"
                id={"#{@id}-group-#{group.key}-more"}
                phx-click="browse"
                phx-value-group={group.key}
                phx-target={@myself}
                class="btn btn-ghost btn-xs w-full justify-start gap-1 font-normal text-primary"
              >
                {gettext("Browse more")} <.icon name="hero-chevron-right" class="w-3.5 h-3.5" />
              </button>
            </section>
            <p
              :if={(@home || []) |> Enum.all?(&(&1.rows == []))}
              class="px-2 py-2 text-sm text-base-content/60"
            >
              {gettext("Nobody to choose yet")}
            </p>
          </div>

          <div :if={@view != :home}>
            <div class="flex items-center gap-2 px-1 py-1">
              <button
                :if={match?({:group, _}, @view)}
                type="button"
                id={"#{@id}-back"}
                phx-click="back"
                phx-target={@myself}
                class="btn btn-ghost btn-xs gap-1"
              >
                <.icon name="hero-chevron-left" class="w-3.5 h-3.5" /> {gettext("Back")}
              </button>
              <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                {view_title(@view, @home)}
              </span>
            </div>
            <ul
              id={"#{@id}-options"}
              phx-update="stream"
              phx-viewport-bottom={@cursor && "more"}
              phx-target={@myself}
              class="flex flex-col"
            >
              <li
                :for={{dom_id, row} <- @streams.options}
                id={"#{@id}-#{dom_id}"}
                class={[row[:member?] && "pl-4"]}
              >
                <.option row={row} selected={@selected} myself={@myself} />
              </li>
            </ul>
            <p :if={@listed == %{}} id={"#{@id}-none"} class="px-2 py-2 text-sm text-base-content/60">
              {gettext("No matches")}
            </p>
          </div>
        </div>
      </div>

      <div
        :if={@can_edit and @recent_shown != []}
        id={"#{@id}-recent"}
        class="flex flex-wrap items-center gap-1.5"
      >
        <span class="text-xs text-base-content/60">{gettext("Recent:")}</span>
        <button
          :for={r <- @recent_shown}
          type="button"
          phx-click="recent"
          phx-value-kind={r.kind}
          phx-value-uuid={r.uuid}
          phx-target={@myself}
          class="btn btn-xs btn-ghost border-base-300 gap-1 font-normal"
          title={r[:sublabel] || r.label}
        >
          <.face row={r} size="xs" />{r.label}
        </button>
      </div>
    </div>
    """
  end

  defp view_title({:group, key}, home) do
    Enum.find_value(home || [], fn group -> group.key == key && group.label end)
  end

  defp view_title({:search, _}, _home), do: gettext("Search results")
  defp view_title(_, _home), do: nil

  attr :id, :string, required: true
  attr :key, :any, required: true
  attr :row, :map, default: nil
  attr :tags, :list, default: []
  attr :can_edit, :boolean, default: true
  attr :myself, :any, required: true

  defp chip(assigns) do
    {kind, uuid} = assigns.key

    assigns =
      assign(assigns, kind: kind, uuid: uuid, name: (assigns.row && assigns.row.label) || "")

    ~H"""
    <div
      id={"#{@id}-chip-#{@kind}-#{@uuid}"}
      data-kind={@kind}
      class="flex items-center gap-2 rounded-box border border-base-300 py-1.5 pl-2 pr-1 min-w-0 max-w-full"
    >
      <.face row={@row} size="sm" />
      <div class="min-w-0">
        <div class="truncate font-medium text-sm">
          {(@row && @row.label) || gettext("No longer listed")}
        </div>
        <div :if={@row && @row[:sublabel]} class="truncate text-xs text-base-content/60">
          {@row.sublabel}
        </div>
        <div :if={@tags != []} class="flex flex-wrap gap-1 mt-0.5" data-tags>
          <span :for={tag <- @tags} class={["badge badge-xs h-auto", tag_class(tag)]}>{tag_label(tag)}</span>
        </div>
      </div>
      <button
        :if={@can_edit}
        type="button"
        id={"#{@id}-remove-#{@kind}-#{@uuid}"}
        phx-click="remove"
        phx-value-kind={@kind}
        phx-value-uuid={@uuid}
        phx-target={@myself}
        class="btn btn-ghost btn-xs btn-circle shrink-0"
        aria-label={gettext("Remove %{name}", name: @name)}
        title={gettext("Remove %{name}", name: @name)}
      >
        <.icon name="hero-x-mark" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :selected, :list, required: true
  attr :myself, :any, required: true

  # One option: a press adds it, or takes it off when it is chosen.
  defp option(assigns) do
    assigns = assign(assigns, :on?, {assigns.row.kind, assigns.row.uuid} in assigns.selected)

    ~H"""
    <button
      type="button"
      role="option"
      aria-selected={to_string(@on?)}
      phx-click="toggle"
      phx-value-kind={@row.kind}
      phx-value-uuid={@row.uuid}
      phx-target={@myself}
      data-pick={"#{@row.kind}:#{@row.uuid}"}
      class={[
        "flex w-full items-center gap-2 rounded px-2 py-1 text-left hover:bg-base-200",
        @on? && "bg-primary/5"
      ]}
    >
      <.face row={@row} size="xs" />
      <span class="min-w-0 flex-1">
        <span class="block truncate text-sm">{@row.label}</span>
        <span :if={@row[:sublabel]} class="block truncate text-xs text-base-content/60">{@row.sublabel}</span>
      </span>
      <.icon :if={@on?} name="hero-check" class="w-4 h-4 shrink-0 text-primary" />
    </button>
    """
  end

  attr :row, :map, default: nil
  attr :size, :string, default: "sm"

  # A person's avatar (letters from the name shown), a group's stacked
  # faces, else the row's icon.
  defp face(assigns) do
    ~H"""
    <%= cond do %>
      <% @row && is_map(@row[:user]) -> %>
        <.user_avatar user={@row.user} name={@row[:name] || @row.label} size={@size} class="shrink-0" />
      <% @row && @row[:faces] not in [nil, []] -> %>
        <span class="flex -space-x-2 shrink-0">
          <.user_avatar
            :for={face <- Enum.take(@row.faces, 3)}
            user={face}
            size="xs"
            class="ring-1 ring-base-100"
          />
        </span>
      <% true -> %>
        <span class={[
          "inline-flex items-center justify-center rounded-full bg-base-200 shrink-0",
          if(@size == "xs", do: "w-6 h-6", else: "w-8 h-8")
        ]}>
          <.icon name={(@row && @row[:icon]) || "hero-user"} class="w-4 h-4 text-base-content/60" />
        </span>
    <% end %>
    """
  end

  defp tag_label(%{label: label}), do: label
  defp tag_label(label) when is_binary(label), do: label
  defp tag_label(_), do: ""

  defp tag_class(%{tone: :info}), do: "badge-info badge-soft"
  defp tag_class(%{tone: :success}), do: "badge-success badge-soft"
  defp tag_class(%{tone: :warning}), do: "badge-warning badge-soft"
  defp tag_class(_), do: "badge-ghost"
end
