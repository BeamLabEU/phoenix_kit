defmodule PhoenixKitWeb.Components.Core.FileDetailsFields do
  @moduledoc """
  The title, alt text and description of a media file, in every language of the
  site at once: a tab per language, one form, one Save.

  Each language is a panel with its own three inputs, named
  `details[<language>][title]` (and `alt`, `description`), so a form posts a
  block per language and `PhoenixKit.Modules.Storage.FileDetails.by_language/3`
  reads it back. The tabs only show and hide panels, **in the browser**
  (`Phoenix.LiveView.JS`): nothing is sent to the server when you switch, so
  what you have typed in another language is still there, and the page's own
  language is not touched. LiveView keeps a tab's state across the form's
  re-renders.

  A site with one language has no tabs: its one panel is shown as it is.
  The inputs show the language's **own** text; the primary language's text is
  only a placeholder, so an untouched language is not saved as a copy of it.
  A tab whose language has no text yet carries a dot.

  Used by the viewer's sidebar, the one place a file's text is edited.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias Phoenix.LiveView.JS

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  @blank %{title: "", alt: "", description: ""}

  attr :id, :string, required: true, doc: "DOM id prefix; unique on the page"

  attr :languages, :list,
    default: [],
    doc: "tabs from `Multilang.build_language_tabs/0`; `[]` on a single-language site"

  attr :lang, :string, required: true, doc: "the language shown first (the only one without tabs)"

  attr :values, :map,
    required: true,
    doc: "`%{language => %{title:, alt:, description:}}`: each language's own text"

  attr :placeholders, :map, default: @blank, doc: "the primary language's text, as placeholders"
  attr :show_alt, :boolean, default: true, doc: "alt text is for images"
  attr :labels, :boolean, default: true, doc: "a label above each input"
  attr :name, :string, default: "details", doc: "the form field prefix"

  def file_details_fields(assigns) do
    panels = panels(assigns.languages, assigns.lang)
    selected = Enum.find_index(panels, &(&1.code == assigns.lang)) || 0

    assigns = assign(assigns, panels: panels, selected: selected, count: length(panels))

    ~H"""
    <div id={@id} class="space-y-2">
      <div
        :if={@count > 1}
        role="tablist"
        class="tabs tabs-border tabs-xs flex-wrap"
        aria-label={gettext("Language")}
      >
        <button
          :for={{panel, i} <- Enum.with_index(@panels)}
          type="button"
          role="tab"
          id={"#{@id}-tab-#{i}"}
          class={["tab gap-1", i == @selected && "tab-active"]}
          title={panel.name}
          phx-click={select_tab(@id, i, @count)}
        >
          <span :if={panel.flag}>{panel.flag}</span>
          <span>{panel.label}</span>
          <.icon :if={panel.is_primary} name="hero-star-mini" class="w-3 h-3 text-warning" />
          <span
            :if={blank?(@values[panel.code])}
            class="w-1.5 h-1.5 rounded-full bg-base-content/30"
            title={gettext("No translation yet")}
            aria-label={gettext("No translation yet")}
          ></span>
        </button>
      </div>

      <div
        :for={{panel, i} <- Enum.with_index(@panels)}
        id={"#{@id}-panel-#{i}"}
        role="tabpanel"
        class={["space-y-2", i != @selected && "hidden"]}
      >
        <% own = Map.merge(%{title: "", alt: "", description: ""}, @values[panel.code] || %{}) %>
        <label class="block">
          <span :if={@labels} class="text-xs font-semibold text-base-content/70">
            {gettext("Title")}
          </span>
          <input
            type="text"
            id={"#{@id}-#{i}-title"}
            name={field_name(@name, panel.code, "title")}
            value={own.title}
            aria-label={gettext("Title")}
            placeholder={placeholder(@placeholders.title, gettext("Title"))}
            class="input input-sm w-full"
          />
        </label>
        <label :if={@show_alt} class="block">
          <span :if={@labels} class="text-xs font-semibold text-base-content/70">
            {gettext("Alt text")}
          </span>
          <input
            type="text"
            id={"#{@id}-#{i}-alt"}
            name={field_name(@name, panel.code, "alt")}
            value={own.alt}
            aria-label={gettext("Alt text")}
            placeholder={placeholder(@placeholders.alt, gettext("Alt text"))}
            class="input input-sm w-full"
          />
        </label>
        <label class="block">
          <span :if={@labels} class="text-xs font-semibold text-base-content/70">
            {gettext("Description")}
          </span>
          <textarea
            id={"#{@id}-#{i}-description"}
            name={field_name(@name, panel.code, "description")}
            aria-label={gettext("Description")}
            placeholder={placeholder(@placeholders.description, gettext("Description"))}
            rows="3"
            class="textarea textarea-sm w-full"
          >{own.description}</textarea>
        </label>
      </div>
    </div>
    """
  end

  # One panel per tab; a site with one language has the one panel for `lang`.
  defp panels([], lang),
    do: [%{code: lang, name: nil, label: nil, flag: nil, is_primary: false}]

  defp panels(tabs, _lang) do
    Enum.map(tabs, fn tab ->
      %{
        code: tab.code,
        name: tab.name,
        label: tab[:short_code] || String.upcase(tab.code),
        flag: tab[:flag],
        is_primary: tab[:is_primary] == true
      }
    end)
  end

  # Shows panel `i`, hides the others, and moves the tab highlight. Client-side
  # only: LiveView re-applies these across re-renders, and nothing is sent.
  defp select_tab(id, i, count) do
    Enum.reduce(0..(count - 1), %JS{}, fn j, js ->
      if j == i do
        js
        |> JS.show(to: "##{id}-panel-#{j}")
        |> JS.add_class("tab-active", to: "##{id}-tab-#{j}")
      else
        js
        |> JS.hide(to: "##{id}-panel-#{j}")
        |> JS.remove_class("tab-active", to: "##{id}-tab-#{j}")
      end
    end)
  end

  defp field_name(prefix, code, field), do: "#{prefix}[#{code}][#{field}]"

  defp placeholder(text, fallback) when text in [nil, ""], do: fallback
  defp placeholder(text, _fallback), do: text

  defp blank?(nil), do: true
  defp blank?(values), do: Enum.all?(Map.values(values), &(&1 in [nil, ""]))
end
