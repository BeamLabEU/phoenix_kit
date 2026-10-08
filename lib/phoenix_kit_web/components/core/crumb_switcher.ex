defmodule PhoenixKitWeb.Components.Core.CrumbSwitcher do
  @moduledoc """
  A ▾ beside a breadcrumb segment that opens a searchable list of the other
  things on that level — GitHub's repository switcher, for any trail: the
  other catalogues beside this one, the categories beside this category.

  The admin header renders it for you: give a `page_crumbs` entry a
  `:switcher`, or the page title a `page_title_switcher`. Use the component
  directly only for a trail you draw yourself.

  ## The switcher map

      %{
        title: "Switch catalogue",               # heading + the button's label
        search_placeholder: "Find a catalogue…", # optional, defaults to "Search..."
        items: [
          %{label: "Kitchen", navigate: "/…", current: true},
          %{label: "Bathroom", navigate: "/…"},
          %{label: "Doors", patch: "/…"}          # same-LiveView move
        ]
      }

  An item may carry a `:hint` — a short muted word after the label ("Site",
  "Mine") to tell apart rows that share a list. It is display only: the
  filter matches the label.

  Each item is a real link — `navigate` (another LiveView) or `patch` (the
  same one) — so middle-click and copy-link keep working. `current: true`
  ticks it. The list filters as you type, on the client (case and accents
  ignored), and Enter opens the first match.

  Open and close are client-side (`PopoverPanel`): instant, Escape and a
  click away close it, and on a phone it becomes a full-screen sheet. The
  `CrumbSwitcher` hook keeps the rest honest whichever way it opened or
  closed: the search starts empty and takes focus on open, focus returns to
  the ▾ on close, and the ▾'s `aria-expanded` follows the panel. Tab stays
  inside the open panel.
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.PopoverPanel

  attr :id, :string, required: true, doc: "DOM id of the panel; must be unique on the page"

  attr :switcher, :map,
    required: true,
    doc: "`%{title:, items:, search_placeholder:}`, see the moduledoc"

  def crumb_switcher(assigns) do
    placeholder = Map.get(assigns.switcher, :search_placeholder) || gettext("Search...")
    title = Map.get(assigns.switcher, :title)

    assigns =
      assign(assigns,
        items: Map.get(assigns.switcher, :items, []),
        title: title,
        placeholder: placeholder,
        # A switcher map without a title still gets a named button.
        label: title || placeholder
      )

    ~H"""
    <span
      id={"#{@id}-switcher"}
      phx-hook="CrumbSwitcher"
      data-panel={@id}
      class="relative inline-flex shrink-0"
    >
      <button
        type="button"
        data-switcher-trigger
        phx-click={toggle_popover(@id)}
        class="btn btn-ghost btn-xs btn-square text-base-content/50 hover:text-base-content"
        aria-haspopup="dialog"
        aria-expanded="false"
        aria-controls={@id}
        aria-label={@label}
        title={@label}
      >
        <.icon name="hero-chevron-down-mini" class="w-4 h-4" />
      </button>
      <.popover_panel id={@id} align="start" width_class="sm:w-80">
        <.focus_wrap id={"#{@id}-focus"}>
          <div class="p-3 border-b border-base-content/10 space-y-2">
            <div :if={@title} class="text-sm font-semibold text-base-content">{@title}</div>
            <label class="input input-sm w-full">
              <.icon name="hero-magnifying-glass" class="w-4 h-4 opacity-50" />
              <input
                id={"#{@id}-search"}
                type="search"
                phx-hook="ListFilter"
                data-filter-list={"##{@id}-list"}
                placeholder={@placeholder}
                aria-label={@placeholder}
                autocomplete="off"
                class="grow"
              />
            </label>
          </div>
          <ul id={"#{@id}-list"} class="max-h-80 overflow-y-auto p-1 text-sm font-normal">
            <%!-- The JS hide rides on the <li>, not the link: the link's own
               navigate/patch still runs, and the panel is not left open
               over the page a patch leaves in place. --%>
            <li :for={item <- @items} data-filter-text={item.label} phx-click={hide_popover(@id)}>
              <.link
                navigate={item[:navigate]}
                patch={item[:patch]}
                aria-current={item[:current] && "page"}
                class={[
                  "flex items-center gap-2 rounded-field px-2 py-1.5 hover:bg-base-200",
                  "focus:bg-base-200 focus:outline-none",
                  item[:current] && "font-semibold"
                ]}
              >
                <.icon
                  name="hero-check-mini"
                  class={"w-4 h-4 shrink-0" <> if(item[:current], do: "", else: " invisible")}
                />
                <span class="truncate">{item.label}</span>
                <span :if={item[:hint]} class="ml-auto shrink-0 text-xs text-base-content/50">
                  {item.hint}
                </span>
              </.link>
            </li>
            <li data-filter-empty class="hidden px-2 py-1.5 text-base-content/50">
              {gettext("No results.")}
            </li>
          </ul>
        </.focus_wrap>
      </.popover_panel>
    </span>
    """
  end
end
