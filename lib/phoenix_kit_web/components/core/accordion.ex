defmodule PhoenixKitWeb.Components.Core.Accordion do
  @moduledoc """
  Collapsible content section on the native `<details>` element + daisyUI
  `collapse` styling.

  The browser owns the open/closed state: the summary click toggles
  natively (instant, no round trip) and daisyUI 5 animates the reveal
  via its `::details-content` height transition. `JS.ignore_attributes`
  marks `open` as client-owned on mount, so LiveView patches never
  reset a section the user toggled — the historic "accordion slams
  shut on the next update" morphdom bug.

  `open` sets only the INITIAL state (server changes to it after mount
  are ignored by design). To open a section from elsewhere in the page,
  set the attribute client-side:

      <button type="button" phx-click={JS.set_attribute({"open", ""}, to: "#advanced")}>
        Show advanced settings
      </button>

  Works without JavaScript (native `<details>` on dead renders).

  Closing a section near the bottom of a long page would shrink the document
  out from under the reader and jump the viewport upward; the collapse scroll
  keeper in `priv/static/assets/phoenix_kit.js` holds the page height instead,
  so the reader stays put. It keys off `class="collapse"` on the `<details>`,
  which this component always emits.

  ## Look

  By default the section is drawn like core's own cards: `bg-base-100` with a
  `border-base-300` edge and `shadow-sm`. On the dark themes `base-200` sits
  within a few hundredths of lightness of `base-100`, so a `border-base-200`
  edge vanished against the page. A caller that wants a flat, filled section
  passes its own classes (e.g. `class="bg-base-200 border-0 shadow-none"`).
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias PhoenixKitWeb.Components.Core.ChangeCue

  attr :id, :string, required: true
  attr :open, :boolean, default: false, doc: "initial state only — client-owned after mount"
  attr :class, :any, default: nil, doc: "extra classes on the <details>"
  attr :title_class, :any, default: nil, doc: "extra classes on the summary"

  attr :cue, :boolean,
    default: false,
    doc:
      "opt into `PhoenixKitWeb.Components.Core.ChangeCue`: the section can be highlighted when " <>
        "something inside it changes while the reader is elsewhere, and carries a quiet marker " <>
        "until they open it"

  attr :cue_label, :string, default: nil, doc: "wording for that marker (default \"Updated\")"

  slot :title, required: true
  slot :content, required: true

  def accordion(assigns) do
    ~H"""
    <details
      id={@id}
      open={@open}
      data-change-region={@cue && @id}
      phx-mounted={JS.ignore_attributes(cue_owned_attributes(@cue))}
      class={["collapse collapse-arrow border border-base-300 bg-base-100 shadow-sm", @class]}
    >
      <%!-- Opening a cued region is the reader SEEING it, which is what
           resets its baseline server-side. Alongside the native toggle,
           not instead of it. --%>
      <summary
        class={["collapse-title text-sm font-semibold", @title_class]}
        phx-click={@cue && JS.push(ChangeCue.seen_event(), value: %{"region" => @id})}
      >
        {render_slot(@title)}
        <ChangeCue.change_marker :if={@cue} label={@cue_label} />
      </summary>
      <div class="collapse-content">
        {render_slot(@content)}
      </div>
    </details>
    """
  end

  # `data-changed` is set by the client and must survive patches for the
  # same reason `open` must: the server has no idea the reader hasn't
  # looked yet, and morphdom would drop the marker on the next keystroke.
  defp cue_owned_attributes(true), do: ["open", "data-changed"]
  defp cue_owned_attributes(_), do: ["open"]
end
