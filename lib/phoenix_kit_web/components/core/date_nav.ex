defmodule PhoenixKitWeb.Components.Core.DateNav do
  @moduledoc ~S"""
  Previous / next / today navigation over a date kept in the URL — the
  header of a page that shows one day at a time (a day's analytics, a
  schedule, a log).

  Stateless: the buttons are `<.link patch>`es built by the `path` function
  you pass, so the date lives in the URL and the page's `handle_params/3`
  reads it (parse it with `parse_param/2`). Previous and next are disabled
  at `min` / `max`; "Today" shows only when you are not already on it.

      <.date_nav
        date={@date}
        today={@today}
        max={@today}
        path={&Routes.path("/admin/analytics?date=#{&1}")}
      />

      def handle_params(params, _uri, socket) do
        today = MyApp.local_today()
        {:noreply, assign(socket, date: DateNav.parse_param(params["date"], today: today, max: today))}
      end

  ## The date picker

  With `picker` (default `true`) a `date_input/1` (the site's date format, a
  calendar button) sits between the arrows. It is `required`: clearing it
  would only make `parse_param/2` answer today. A date input only reaches the
  server inside a form, so it is
  wrapped in one that sends `pick_event` (default `"date_nav_pick"`) with
  `%{"date" => "YYYY-MM-DD"}`; handle it with a patch:

      def handle_event("date_nav_pick", %{"date" => value}, socket) do
        date = DateNav.parse_param(value, today: socket.assigns.today)
        {:noreply, push_patch(socket, to: Routes.path("/admin/analytics?date=#{date}"))}
      end

  The date is written with `PhoenixKit.Utils.Date.short_with_year/1`, in
  the viewer's language.

  ## A week at a time, and views with no URL

  `step` is how many days one press moves, and `label` what stands between
  the arrows in the date's place. A view that cannot patch — a LiveView
  nested in another page — passes `event` instead of `path`: the arrows and
  the way back to today then send it with `%{"date" => "YYYY-MM-DD"}`.

      <.date_nav
        id="timesheet-week"
        date={@week}
        today={@this_week}
        step={7}
        label={"\#{short(@week)} – \#{short(Date.add(@week, 6))}"}
        today_label={gettext("This week")}
        event="sheet_week"
      />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.DateInput, only: [date_input: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.Utils.Date, as: UtilsDate

  attr :date, Date, required: true

  attr :path, :any,
    default: nil,
    doc: "1-arity function: `Date.t()` → the URL for that date. Required unless `event` is set."

  attr :event, :string,
    default: nil,
    doc:
      ~s(Instead of patch links: the buttons send this event with `%{"date" => "YYYY-MM-DD"}`. ) <>
        "For a view with no URL of its own — a LiveView nested in another page, a tab."

  attr :target, :any,
    default: nil,
    doc: "`phx-target` for `event` and for the day picker's `pick_event`."

  attr :step, :integer,
    default: 1,
    doc: "Days one press moves: `7` steps a week at a time (`date` is then the week's first day)."

  attr :label, :string,
    default: nil,
    doc:
      "What stands between the arrows instead of the date (and the picker): " <>
        "\"Oct 12 – Oct 18\" for a week."

  attr :today, Date, default: nil, doc: "The viewer's today (default: UTC today)"

  attr :today_label, :string,
    default: nil,
    doc:
      "The word for the way back to `today` (default \"Today\"; \"This week\" with `step={7}`)."

  attr :min, Date, default: nil
  attr :max, Date, default: nil
  attr :picker, :boolean, default: true
  attr :pick_event, :string, default: "date_nav_pick"
  attr :id, :string, default: "date-nav"
  attr :class, :any, default: nil
  attr :rest, :global

  def date_nav(assigns) do
    today = assigns.today || Date.utc_today()
    step = max(assigns.step, 1)
    prev = Date.add(assigns.date, -step)
    next = Date.add(assigns.date, step)

    assigns =
      assigns
      |> assign(:today_date, today)
      |> assign(:prev, if(before_min?(prev, assigns.min), do: nil, else: prev))
      |> assign(:next, if(after_max?(next, assigns.max), do: nil, else: next))
      |> assign(
        :prev_label,
        if(step == 1, do: gettext("Previous day"), else: gettext("Previous"))
      )
      |> assign(:next_label, if(step == 1, do: gettext("Next day"), else: gettext("Next")))
      |> assign(:today_word, assigns.today_label || gettext("Today"))
      # A label replaces the date between the arrows, and with it the picker:
      # a date input picks a day, which is not what a week is.
      |> assign(:show_picker?, assigns.picker and is_nil(assigns.label))

    ~H"""
    <div id={@id} class={["flex flex-wrap items-center gap-2", @class]} {@rest}>
      <div class="join">
        <.step_button
          to={@prev}
          path={@path}
          event={@event}
          target={@target}
          label={@prev_label}
          icon="hero-chevron-left"
        />

        <form
          :if={@show_picker?}
          id={"#{@id}-picker"}
          phx-change={@pick_event}
          phx-target={@target}
          class="join-item"
          onsubmit="return false"
        >
          <.date_input
            id={"#{@id}-date"}
            name="date"
            value={@date}
            min={@min}
            max={@max}
            required
            bare
            size="sm"
            label={gettext("Date")}
            class="join-item rounded-none w-38"
          />
        </form>
        <span :if={!@show_picker?} class="btn btn-sm join-item pointer-events-none font-normal">
          {@label || UtilsDate.short_with_year(@date)}
        </span>

        <.step_button
          to={@next}
          path={@path}
          event={@event}
          target={@target}
          label={@next_label}
          icon="hero-chevron-right"
        />
      </div>

      <%= if @date != @today_date and not after_max?(@today_date, @max) and not before_min?(@today_date, @min) do %>
        <button
          :if={@event}
          type="button"
          phx-click={@event}
          phx-value-date={Date.to_iso8601(@today_date)}
          phx-target={@target}
          class="btn btn-sm btn-ghost"
        >
          {@today_word}
        </button>
        <.link :if={!@event} patch={@path.(@today_date)} class="btn btn-sm btn-ghost">
          {@today_word}
        </.link>
      <% end %>
      <span :if={@date == @today_date} class="text-sm text-base-content/60">
        {@today_word}
      </span>
    </div>
    """
  end

  attr :to, Date, default: nil
  attr :path, :any, default: nil
  attr :event, :string, default: nil
  attr :target, :any, default: nil
  attr :label, :string, required: true
  attr :icon, :string, required: true

  # One arrow: a patch link, a button sending `event`, or — at `min` / `max`
  # — the same shape, disabled.
  defp step_button(%{to: nil} = assigns) do
    ~H"""
    <span class="btn btn-sm join-item btn-disabled" aria-disabled="true" aria-label={@label}>
      <.icon name={@icon} class="w-4 h-4" />
    </span>
    """
  end

  defp step_button(%{event: event} = assigns) when is_binary(event) do
    ~H"""
    <button
      type="button"
      phx-click={@event}
      phx-value-date={Date.to_iso8601(@to)}
      phx-target={@target}
      class="btn btn-sm join-item"
      aria-label={@label}
      title={@label}
    >
      <.icon name={@icon} class="w-4 h-4" />
    </button>
    """
  end

  defp step_button(assigns) do
    ~H"""
    <.link patch={@path.(@to)} class="btn btn-sm join-item" aria-label={@label} title={@label}>
      <.icon name={@icon} class="w-4 h-4" />
    </.link>
    """
  end

  @doc """
  Reads a `"YYYY-MM-DD"` URL or form value into a date. Anything that is
  not a date — missing, garbage — is `today`; a date outside `min` / `max`
  is clamped to the nearer end.

  Options: `:today` (default UTC today), `:min`, `:max`.
  """
  @spec parse_param(term(), keyword()) :: Date.t()
  def parse_param(value, opts \\ []) do
    today = Keyword.get(opts, :today) || Date.utc_today()

    date =
      case is_binary(value) && Date.from_iso8601(String.trim(value)) do
        {:ok, date} -> date
        _ -> today
      end

    date
    |> clamp_min(opts[:min])
    |> clamp_max(opts[:max])
  end

  defp clamp_min(date, nil), do: date
  defp clamp_min(date, min), do: if(Date.compare(date, min) == :lt, do: min, else: date)

  defp clamp_max(date, nil), do: date
  defp clamp_max(date, max), do: if(Date.compare(date, max) == :gt, do: max, else: date)

  defp before_min?(_date, nil), do: false
  defp before_min?(date, min), do: Date.compare(date, min) == :lt

  defp after_max?(_date, nil), do: false
  defp after_max?(date, max), do: Date.compare(date, max) == :gt
end
