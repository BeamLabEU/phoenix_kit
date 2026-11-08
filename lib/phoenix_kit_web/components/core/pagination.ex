defmodule PhoenixKitWeb.Components.Core.Pagination do
  @moduledoc """
  Pagination components for list views in PhoenixKit.

  Provides pagination controls and information display following daisyUI design patterns.

  Two flavours:

    * Page-numbered (`<.pagination>`, `<.pagination_controls>`,
      `<.pagination_info>`) — URL-param driven, suits standalone admin
      pages with deep-linkable state. `<.page_size_selector>` sits next to
      either and lets the viewer pick the rows per page.
      `<.pagination_bar>` is the three together, the footer every admin list
      uses, with the size remembered per person (`PhoenixKitWeb.PageSize`).

    * Load-more (`<.load_more>`) — click-driven LV event that grows
      the loaded set in place. Suits embeddable LVs (no URL routing),
      lists with DnD reorder (rows append, don't replace), and lists
      with client-side bulk-select (selection persists across loads
      because rows stay in the DOM).
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  @doc """
  Displays pagination controls with page numbers and navigation buttons.

  Two modes. With `build_url` every page is a patch link (URL-driven pages).
  With `on_page` every page is a button that sends that LiveView event with
  `phx-value-page` (embeddable views with no URL of their own; `target` is its
  `phx-target`, a LiveComponent's `@myself`). `build_url` is required unless
  `on_page` is set: with neither, rendering raises an `ArgumentError`.

  ## Attributes
  - `page` - Current page number (required)
  - `total_pages` - Total number of pages (required)
  - `build_url` - Function that takes page number and returns URL (links mode)
  - `on_page` - Event name; set it for buttons instead of links (events mode)
  - `target` - `phx-target` of the events (events mode)
  - `class` - Additional CSS classes

  ## Examples

      <.pagination_controls
        page={@page}
        total_pages={@total_pages}
        build_url={&build_page_url(&1, assigns)}
      />

      <.pagination_controls
        page={@page}
        total_pages={@total_pages}
        on_page="set_page"
        target={@myself}
      />
  """
  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :build_url, :any, default: nil
  attr :on_page, :string, default: nil
  attr :target, :any, default: nil
  attr :class, :string, default: ""

  def pagination_controls(%{on_page: on_page} = assigns) when is_binary(on_page) do
    ~H"""
    <div :if={@total_pages > 1} class={["join", @class]}>
      <button
        :if={@page > 1}
        type="button"
        phx-click={@on_page}
        phx-value-page={@page - 1}
        phx-target={@target}
        class="join-item btn btn-sm"
      >
        « {gettext("Prev")}
      </button>

      <button
        :for={page_num <- pagination_range(@page, @total_pages)}
        type="button"
        phx-click={@on_page}
        phx-value-page={page_num}
        phx-target={@target}
        class={["join-item btn btn-sm", page_num == @page && "btn-active"]}
      >
        {page_num}
      </button>

      <button
        :if={@page < @total_pages}
        type="button"
        phx-click={@on_page}
        phx-value-page={@page + 1}
        phx-target={@target}
        class="join-item btn btn-sm"
      >
        {gettext("Next")} »
      </button>
    </div>
    """
  end

  def pagination_controls(%{build_url: nil}) do
    raise ArgumentError,
          "pagination_controls needs either build_url (links) or on_page (events)"
  end

  def pagination_controls(assigns) do
    ~H"""
    <div :if={@total_pages > 1} class={["join", @class]}>
      <%= if @page > 1 do %>
        <.link patch={@build_url.(@page - 1)} class="join-item btn btn-sm">
          « Prev
        </.link>
      <% end %>

      <%= for page_num <- pagination_range(@page, @total_pages) do %>
        <.link
          patch={@build_url.(page_num)}
          class={["join-item btn btn-sm", page_num == @page && "btn-active"]}
        >
          {page_num}
        </.link>
      <% end %>

      <%= if @page < @total_pages do %>
        <.link patch={@build_url.(@page + 1)} class="join-item btn btn-sm">
          Next »
        </.link>
      <% end %>
    </div>
    """
  end

  @doc """
  Displays pagination information showing result range.

  ## Attributes
  - `page` - Current page number (required)
  - `per_page` - Items per page (required)
  - `total_count` - Total number of items (required)
  - `class` - Additional CSS classes

  ## Examples

      <.pagination_info
        page={@page}
        per_page={@per_page}
        total_count={@total_count}
      />

      # Renders: "Showing 1 to 25 of 100 results"
      # Single-page result drops the redundant " of N" — e.g. with
      # total_count=4 and per_page=25: "Showing 1 to 4 results".

  Every string is translated. `noun_plural` names what is being counted
  (default `gettext("results")`); pass an already-translated word so the
  line reads "… of 40 sessions" in the viewer's language:

      <.pagination_info
        page={@page}
        per_page={@per_page}
        total_count={@total_count}
        noun_plural={gettext("sessions")}
      />
  """
  attr :page, :integer, required: true
  attr :per_page, :integer, required: true
  attr :total_count, :integer, required: true
  attr :noun_plural, :string, default: nil
  attr :class, :string, default: ""

  def pagination_info(assigns) do
    # Resolved at render time so the default follows the viewer's locale,
    # not the locale the module happened to compile under.
    assigns = assign(assigns, :noun_plural, assigns.noun_plural || gettext("results"))

    ~H"""
    <div class={["text-sm text-base-content/70", @class]}>
      <%= cond do %>
        <% @total_count == 0 -> %>
          {gettext("No %{noun}", noun: @noun_plural)}
        <% @total_count > @per_page -> %>
          {gettext("Showing %{from} to %{to} of %{total} %{noun}",
            from: (@page - 1) * @per_page + 1,
            to: min(@page * @per_page, @total_count),
            total: @total_count,
            noun: @noun_plural
          )}
        <% true -> %>
          {gettext("Showing %{from} to %{to} %{noun}",
            from: (@page - 1) * @per_page + 1,
            to: min(@page * @per_page, @total_count),
            noun: @noun_plural
          )}
      <% end %>
    </div>
    """
  end

  @doc """
  Renders complete pagination controls with automatic URL building.

  Simpler alternative to pagination_controls that handles URL building internally.
  Preserves all query parameters while changing page number.

  ## Attributes
  - `current_page` - Current active page number (required)
  - `total_pages` - Total number of pages available (required)
  - `base_path` - Base URL path without query params (required)
  - `params` - Map of query parameters to preserve (default: %{})

  ## Examples

      <.pagination
        current_page={@page}
        total_pages={@total_pages}
        base_path="/admin/emails"
        params={%{"search" => @filters.search, "status" => @filters.status}}
      />

      <%!-- Minimal usage --%>
      <.pagination
        current_page={1}
        total_pages={10}
        base_path="/admin/logs"
      />
  """
  attr :current_page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :base_path, :string, required: true
  attr :params, :map, default: %{}

  def pagination(assigns) do
    ~H"""
    <%= if @total_pages > 1 do %>
      <div class="flex justify-center p-4 border-t border-base-300">
        <div class="join">
          <%!-- Previous button --%>
          <%= if @current_page > 1 do %>
            <.link
              patch={build_page_url(@base_path, @params, @current_page - 1)}
              class="join-item btn btn-sm"
            >
              « Prev
            </.link>
          <% end %>
          <%!-- Page numbers (show current ± 2 pages) --%>
          <%= for page_num <- pagination_range(@current_page, @total_pages) do %>
            <.link
              patch={build_page_url(@base_path, @params, page_num)}
              class={[
                "join-item btn btn-sm",
                page_num == @current_page && "btn-active"
              ]}
            >
              {page_num}
            </.link>
          <% end %>
          <%!-- Next button --%>
          <%= if @current_page < @total_pages do %>
            <.link
              patch={build_page_url(@base_path, @params, @current_page + 1)}
              class="join-item btn btn-sm"
            >
              Next »
            </.link>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  The footer of an admin list, the same on every list: how many rows are
  shown on the left, the page buttons in the middle, and the rows-per-page
  selector with Auto on the right. Stacked on a narrow screen. Renders
  nothing for an empty list.

  The selector sends `change_per_page`; hand it to
  `PhoenixKitWeb.PageSize.handle_change/2`, which remembers the size for
  the person across every list.

  ## Attributes
  - `id` - DOM id of the bar; the selector gets `id <> "-per-page"` (required)
  - `page`, `total_pages`, `total_count`, `per_page` - the list's state (required)
  - `build_url` - page number -> URL, as for `<.pagination_controls>` (required)
  - `table_id` - DOM id of the table, which Auto measures (required)
  - `auto` - whether Auto is on (`@auto_fit` from `PageSize.url_params/0`)
  - `noun_plural` - what is counted, already translated ("users")

  ## Example

      <.pagination_bar
        id="users-pagination"
        page={@page}
        total_pages={@total_pages}
        total_count={@total_count}
        per_page={@per_page}
        auto={@auto_fit}
        table_id="users-table"
        noun_plural={gettext("users")}
        build_url={&url_state_path(assigns, page: &1)}
      />
  """
  attr :id, :string, required: true
  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :total_count, :integer, required: true
  attr :per_page, :integer, required: true
  attr :build_url, :any, required: true
  attr :table_id, :string, required: true
  attr :auto, :boolean, default: false
  attr :noun_plural, :string, default: nil
  attr :class, :string, default: ""

  def pagination_bar(assigns) do
    ~H"""
    <div
      :if={@total_count > 0}
      id={@id}
      class={["flex flex-col sm:flex-row items-center gap-4 py-4", @class]}
    >
      <.pagination_info
        page={@page}
        per_page={@per_page}
        total_count={@total_count}
        noun_plural={@noun_plural}
        class="sm:flex-1"
      />
      <.pagination_controls page={@page} total_pages={@total_pages} build_url={@build_url} />
      <div class="sm:flex-1 flex sm:justify-end">
        <.page_size_selector
          id={@id <> "-per-page"}
          value={@per_page}
          options={PhoenixKitWeb.PageSize.sizes()}
          auto_fit
          auto={@auto}
          table_id={@table_id}
        />
      </div>
    </div>
    """
  end

  @doc """
  Rows-per-page selector, a sibling of `<.pagination>`.

  A daisyUI `<select>` wrapped in its own `<form phx-change>`, so a change
  reaches the LiveView as `%{"per_page" => "25"}` under the event named in
  `on_change`. The LiveView is expected to push the value into the URL and
  reset the page to 1 — with `PhoenixKitWeb.Live.UrlState` that is one
  `push_url_state(socket, per_page: n)`, which does both.

  ## Attributes

  - `value` — the current page size (required)
  - `options` — selectable sizes (default `[10, 25, 50, 100]`). A `value`
    outside the list is appended so the select never shows a blank.
  - `on_change` — LV event name (default `"change_per_page"`)
  - `class` — additional classes on the wrapper
  - `id` — DOM id of the `<select>`; the wrapping form gets `id <> "-form"`
    (default `"pk-page-size-" <> on_change` — pass one when a page renders two
    selectors with the same event)
  - `auto_fit` — adds an "Auto" option backed by the `PageSizeAutoFit` JS
    hook, which measures how many rows of `table_id` fit the viewport and
    pushes `on_change` with `%{"per_page" => n, "auto" => "1"}`, `n` being
    the largest option that fits (default `false`)
  - `auto` — whether Auto is currently selected (default `false`)
  - `table_id` — DOM id of the table the hook measures; required when `auto_fit`

  ## Example

      <.page_size_selector value={@per_page} />

      <%!-- Auto-fit pilot --%>
      <.page_size_selector
        id="users-per-page"
        value={@per_page}
        auto_fit
        auto={@auto_fit}
        table_id="users-table"
      />
  """
  attr :value, :integer, required: true
  attr :options, :list, default: [10, 25, 50, 100]
  attr :on_change, :string, default: "change_per_page"
  attr :class, :string, default: ""
  attr :id, :string, default: nil
  attr :auto_fit, :boolean, default: false
  attr :auto, :boolean, default: false
  attr :table_id, :string, default: nil

  def page_size_selector(assigns) do
    if assigns.auto_fit and is_nil(assigns.table_id) do
      raise ArgumentError,
            "<.page_size_selector auto_fit> requires `table_id` (the PageSizeAutoFit JS hook measures that table)"
    end

    options =
      if assigns.value in assigns.options,
        do: assigns.options,
        else: Enum.sort([assigns.value | assigns.options])

    assigns =
      assigns
      |> assign(:options, options)
      |> assign(:id, assigns.id || "pk-page-size-#{assigns.on_change}")

    ~H"""
    <form
      id={"#{@id}-form"}
      phx-change={@on_change}
      class={["flex items-center gap-2 text-sm text-base-content/70", @class]}
    >
      <label for={@id}>{gettext("Rows per page")}</label>
      <select
        id={@id}
        name="per_page"
        class="select select-sm select-bordered w-auto"
        phx-hook={@auto_fit && "PageSizeAutoFit"}
        data-auto={@auto_fit && to_string(@auto)}
        data-table-id={@auto_fit && @table_id}
        data-options={@auto_fit && Enum.join(@options, ",")}
        data-event={@auto_fit && @on_change}
      >
        <option :for={size <- @options} value={size} selected={size == @value and not @auto}>
          {size}
        </option>
        <option :if={@auto_fit} value="auto" selected={@auto}>{gettext("Auto")}</option>
      </select>
    </form>
    """
  end

  @doc """
  Load-more footer for incrementally-loaded lists.

  Renders a centered "Showing N of M %{noun}" line and a "Load more"
  button (hidden when `loaded >= total`). Clicking the button emits
  the LV event named in `on_load_more`.

  Suited for embeddable LVs where URL-param pagination isn't an
  option, lists with DnD reorder (rows append rather than navigate
  away), and lists with client-side bulk-select (selection persists
  because the DOM grows, it doesn't get replaced).

  ## Attributes

  - `loaded` — number of rows currently rendered (required)
  - `total` — total rows matching the current filter/sort (required)
  - `on_load_more` — LV event name pushed on button click
    (default `"load_more"`)
  - `noun_plural` — used in the "Showing N of M %{noun}" line
    (default `"items"`)
  - `class` — additional classes on the outer wrapper
  - `infinite` — when `true`, the footer also auto-loads on scroll via
    the `InfiniteScroll` hook (the manual button stays as a fallback).
    Requires `id`. (default `false`)
  - `id` — DOM id, **required when `infinite`** (the JS hook needs it)
  - `cursor` — an opaque per-page marker (e.g. `"items-<offset>"`) that
    changes on each load. The `InfiniteScroll` hook re-fires only when it
    changes, so it both keeps firing while still on screen and ignores
    unrelated diffs. Only used when `infinite`. Defaults to `@loaded`
    (which already changes per page), so most callers can omit it; pass
    an explicit value only when `@loaded` is not a faithful page marker.

  ## Example

      <.load_more
        loaded={length(@projects)}
        total={@total_count}
        on_load_more="load_more"
        noun_plural={gettext("projects")}
      />

      <%!-- Auto-load on scroll + manual fallback --%>
      <.load_more
        id="items-load-more"
        loaded={length(@items)}
        total={@total}
        infinite
        cursor={"items-\#{@offset}"}
      />
  """
  attr :loaded, :integer, required: true
  attr :total, :integer, required: true
  attr :on_load_more, :string, default: "load_more"
  attr :noun_plural, :string, default: "items"
  attr :class, :string, default: ""
  attr :id, :string, default: nil
  attr :infinite, :boolean, default: false
  attr :cursor, :string, default: ""

  attr :rest, :global,
    doc: """
    Forwarded to the button, so a page with more than one load-more list can
    tell its handler which one was clicked (`phx-value-*`). Without this a
    caller has to mint a separate event name per list.
    """

  def load_more(assigns) do
    if assigns.infinite and is_nil(assigns.id) do
      raise ArgumentError,
            "<.load_more infinite> requires an `id` (the InfiniteScroll JS hook needs it)"
    end

    # Only the infinite variant renders data-cursor; skip the work otherwise.
    assigns =
      assign(
        assigns,
        :effective_cursor,
        if(assigns.infinite, do: resolve_cursor(assigns), else: "")
      )

    ~H"""
    <div
      :if={@total > 0}
      id={@id}
      phx-hook={if @infinite and @loaded < @total, do: "InfiniteScroll"}
      data-load-more-event={@on_load_more}
      data-cursor={@infinite && @effective_cursor}
      class={["flex flex-col items-center gap-2 p-4", @class]}
    >
      <p class="text-sm text-base-content/60">
        {gettext("Showing %{loaded} of %{total} %{noun}",
          loaded: @loaded,
          total: @total,
          noun: @noun_plural
        )}
      </p>
      <button
        :if={@loaded < @total}
        type="button"
        class="btn btn-sm"
        phx-click={@on_load_more}
        phx-disable-with={gettext("Loading…")}
        {@rest}
      >
        {gettext("Load more")}
      </button>
    </div>
    """
  end

  # Private helper functions

  # Per-page marker the InfiniteScroll hook watches. An explicit `cursor`
  # wins; otherwise fall back to `loaded`, which already changes per page so
  # callers don't have to thread a cursor through just to drive auto-load.
  defp resolve_cursor(%{cursor: cursor}) when is_binary(cursor) and cursor != "", do: cursor
  defp resolve_cursor(%{loaded: loaded}) when is_integer(loaded), do: Integer.to_string(loaded)
  defp resolve_cursor(_), do: ""

  # Calculate visible page range (current page ± 2). Callers don't
  # necessarily clamp `current_page` themselves (e.g. a page number from a
  # stale bookmark or a crawled URL) — an unclamped huge current_page with a
  # small total_pages used to produce a DESCENDING range spanning billions
  # of integers (`a..b` picks step -1 whenever a > b), and iterating that in
  # the `:for` below allocated a component per step until the VM OOMed.
  # Clamping current_page into [1, max(total_pages, 1)] first guarantees
  # start_page <= end_page; the explicit `//1` step is a second, independent
  # guard — if start_page were ever still > end_page (e.g. total_pages is 0
  # so the clamp itself has nothing valid to land on), an explicit positive
  # step makes Elixir return an EMPTY range instead of auto-picking -1.
  defp pagination_range(current_page, total_pages) do
    total_pages = max(total_pages, 1)
    current_page = current_page |> max(1) |> min(total_pages)

    start_page = max(1, current_page - 2)
    end_page = min(total_pages, current_page + 2)
    start_page..end_page//1
  end

  # Build URL with query parameters and page number
  defp build_page_url(base_path, params, page) do
    # Add page to params and filter out nil/empty values
    query_params =
      params
      |> Map.put("page", page)
      |> Enum.filter(fn {_k, v} -> v != nil and v != "" end)
      |> Enum.into(%{})

    # Encode query parameters
    query_string = URI.encode_query(query_params)

    # Build final URL
    if query_string == "" do
      base_path
    else
      "#{base_path}?#{query_string}"
    end
  end
end
