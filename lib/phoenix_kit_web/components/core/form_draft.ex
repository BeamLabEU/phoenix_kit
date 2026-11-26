defmodule PhoenixKitWeb.Components.Core.FormDraft do
  @moduledoc """
  Opt-in persisted form drafts: what someone types into a form is kept in
  the browser (`localStorage`, or `sessionStorage`) while they type, and
  offered back when they return to the form before saving it — after a
  reload, a crash, a lost connection or a closed tab.

  The `FormDraft` hook (in `phoenix_kit.js`) does the work; this module
  gives the form its attributes and renders the "Restore your unsaved
  draft?" bar.

  ## Usage

      <.form for={@form} id="post-form" phx-change="validate" phx-submit="save"
        {FormDraft.attrs(exclude: ["slug"])}>
        <FormDraft.form_draft_bar for="post-form" />
        ...
      </.form>

  or, with core's `<.simple_form>`, just `draft`:

      <.simple_form for={@form} id="post-form" phx-submit="save" draft>

  The form needs an `id`. Never kept: password, hidden and file inputs, the
  CSRF token, buttons, fields whose name starts with `_` (LiveView's own),
  fields marked `data-draft-skip`, and the names in `exclude` (a bare name
  also matches it nested: `"email"` excludes `user[email]`).

  ## Options of `attrs/1`

    * `:key` — what the draft is stored under (default: the page's path and
      the form's id). Give a record's id when one page edits many records
      (`key: "post:" <> @post.uuid`), and something per person on a shared
      computer, since `localStorage` outlives a sign-out.
    * `:storage` — `:local` (default) or `:session` (gone with the tab).
    * `:exclude` — field names never stored.
    * `:ttl` — seconds a draft is offered for (default 7 days).
    * `:event` — a server event asked first when a draft is found. It gets
      `%{"id" => form_id, "saved_at" => unix_ms, "fields" => [names]}` and
      answers with `{:reply, %{restore: true}, socket}` (restore it now),
      `%{restore: false}` (throw it away) or `%{}` (show the bar).

  ## Clearing

  The draft goes when the form is submitted and then leaves the page (the
  usual save-and-navigate). A form that stays on the page after a
  successful save clears it from the server: `FormDraft.clear(socket, "post-form")`.
  The server can also `push_event(socket, "pk:form-draft", %{id: id, action: "restore" | "discard"})`.

  While the bar is showing nothing is saved over the old draft, so typing
  before answering it never loses that draft.
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  @default_ttl 7 * 24 * 3600

  @doc """
  The attributes that turn a form's drafts on; spread them onto the
  `<form>` / `<.form>`. See the moduledoc for the options.
  """
  @spec attrs(keyword()) :: map()
  def attrs(opts \\ []) do
    %{
      "phx-hook" => "FormDraft",
      "data-draft-storage" => storage(Keyword.get(opts, :storage, :local)),
      "data-draft-ttl" => to_string(Keyword.get(opts, :ttl, @default_ttl)),
      "data-draft-exclude" => opts |> Keyword.get(:exclude, []) |> Enum.join(",")
    }
    |> put_present("data-draft-key", Keyword.get(opts, :key))
    |> put_present("data-draft-event", Keyword.get(opts, :event))
  end

  defp storage(:session), do: "session"
  defp storage("session"), do: "session"
  defp storage(_), do: "local"

  defp put_present(map, _k, nil), do: map
  defp put_present(map, _k, ""), do: map
  defp put_present(map, k, v), do: Map.put(map, k, to_string(v))

  @doc """
  Clears the draft of form `id` in the browser — after a save that keeps
  the form on the page.
  """
  @spec clear(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def clear(socket, id) when is_binary(id) do
    Phoenix.LiveView.push_event(socket, "pk:form-draft", %{id: id, action: "clear"})
  end

  @doc """
  The "Restore your unsaved draft?" bar of form `for`, hidden until the
  hook finds a draft. Put it inside the form (or anywhere, by `for`).

      <FormDraft.form_draft_bar for="post-form" />
  """
  attr :for, :string, required: true, doc: "the form's id"
  attr :class, :string, default: "mb-4"

  def form_draft_bar(assigns) do
    ~H"""
    <%!-- Ignored by patches: the hook shows and hides the bar inside. --%>
    <div id={@for <> "-draft-bar"} phx-update="ignore" data-pk-draft-bar={@for} class={@class}>
      <div
        data-pk-draft-prompt
        hidden
        role="status"
        class="alert alert-info alert-soft flex flex-wrap items-center gap-2 py-2"
      >
        <span class="flex-1 text-sm">{gettext("Restore your unsaved draft?")}</span>
        <button type="button" class="btn btn-sm btn-primary" data-pk-draft-restore>
          {gettext("Restore")}
        </button>
        <button type="button" class="btn btn-sm btn-ghost" data-pk-draft-discard>
          {gettext("Discard")}
        </button>
      </div>
    </div>
    """
  end
end
