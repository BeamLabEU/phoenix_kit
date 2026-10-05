defmodule PhoenixKit.Mentions.Live do
  @moduledoc """
  Everything a LiveView needs to let people WRITE mentions and act on them:

      use PhoenixKit.Mentions.Live

  That injects the typeahead's search handler and the access-request
  events. In the template, swap a textarea for `<.mention_input>` and drop
  the dialog somewhere:

      <.mention_input field={@form[:description]} label="Description" />
      <.access_request_dialog request={@pk_access_request} />

  Reading mentions needs none of this — `<.mention_text>` is a plain
  function component. This module is only for the two INTERACTIVE halves,
  which is why it is opt-in per LiveView rather than global.

  Injected clauses follow the MediaBrowser embed precedent: a host adds one
  `use` instead of copying four handlers and getting one subtly wrong.
  Every one of them degrades rather than crashes — a click with no dialog
  rendered, or a search with the feature switched off, is a no-op.
  """

  # Fully-qualified inside the quote on purpose: this expands in the
  # CALLER's module, where an alias defined here does not exist.
  # credo:disable-for-this-file Credo.Check.Design.AliasUsage
  defmacro __using__(_opts) do
    quote do
      import PhoenixKit.Mentions.Live, only: [access_request_dialog: 1, mention_input: 1]

      @impl true
      def handle_event("pk_mention_search", params, socket) do
        {:reply, PhoenixKit.Mentions.Live.search_reply(socket, params), socket}
      end

      @impl true
      def handle_event("pk_request_access", %{"type" => type, "uuid" => uuid}, socket) do
        {:noreply,
         Phoenix.Component.assign(socket, :pk_access_request, %{
           type: type,
           uuid: uuid,
           note: "",
           state: :open
         })}
      end

      def handle_event("pk_access_request_close", _params, socket) do
        {:noreply, Phoenix.Component.assign(socket, :pk_access_request, nil)}
      end

      def handle_event("pk_access_request_submit", params, socket) do
        {:noreply, PhoenixKit.Mentions.Live.submit(socket, params)}
      end
    end
  end

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias Phoenix.HTML.Form
  alias PhoenixKit.Mentions
  alias PhoenixKit.Mentions.AccessRequests
  alias PhoenixKitWeb.Actor

  @doc false
  def submit(socket, params) do
    request = socket.assigns[:pk_access_request]

    user_uuid =
      get_in(socket.assigns, [:phoenix_kit_current_scope, Access.key(:user), Access.key(:uuid)])

    cond do
      is_nil(request) ->
        socket

      is_nil(user_uuid) ->
        Phoenix.LiveView.put_flash(socket, :error, gettext("Sign in to request access."))

      true ->
        case AccessRequests.request(request.type, request.uuid, user_uuid,
               note: params["note"],
               source_type: socket.assigns[:pk_access_source_type],
               source_uuid: socket.assigns[:pk_access_source_uuid]
             ) do
          {:ok, _} ->
            socket
            |> Phoenix.Component.assign(:pk_access_request, nil)
            |> Phoenix.LiveView.put_flash(:info, gettext("Access requested."))

          {:error, _} ->
            Phoenix.LiveView.put_flash(socket, :error, gettext("Could not send that request."))
        end
    end
  end

  @doc false
  # The typeahead's server half. Replies rather than assigns: the results
  # belong to one keystroke in one field, and putting them in assigns would
  # re-render the whole form on every character.
  def search_reply(socket, params) do
    kind = if params["kind"] == "user", do: :user, else: :resource
    query = params["query"] || ""

    # The SCOPE, not just the uuid. A handler asks `Authz.admin_all?` (or
    # its own equivalent), which only answers for a scope — pass a bare
    # uuid and a site admin silently gets the membership-only list, so
    # every project they don't personally belong to vanishes from their
    # own typeahead.
    results =
      Mentions.search(kind, query,
        scope: socket.assigns[:phoenix_kit_current_scope],
        user_uuid: Actor.uuid(socket),
        context: context(params["context"])
      )
      |> Enum.map(fn r ->
        kind = if r[:kind] == :user, do: :user, else: :resource

        %{
          kind: Kernel.to_string(kind),
          type: r[:type],
          uuid: r[:uuid],
          title: r[:title],
          subtitle: r[:subtitle],
          # The finished token, built and validated HERE. The client used
          # to assemble it by concatenation, which silently produced
          # something unparseable whenever a record's own name contained a
          # `|` or `]` — "Q3 | Launch" stored a broken token that no
          # renderer would ever link and no index would ever record.
          token: build_token(kind, r)
        }
      end)
      |> Enum.filter(& &1.token)

    # `seq` is echoed back untouched so the client can drop replies for a
    # query the user has already typed past.
    %{results: results, seq: params["seq"]}
  end

  # The field's `data-mention-context`, as the hook sent it: a map of
  # strings, or nothing. Handlers narrow by it; they never trust it for
  # access — the scope decides that.
  defp context(%{} = map), do: map
  defp context(_), do: nil

  # Falls back to a sanitised label rather than dropping the result: a
  # record whose name happens to contain a delimiter should still be
  # mentionable, just under a name the grammar can hold.
  defp build_token(kind, r) do
    case Mentions.Token.to_string(kind, r[:type], r[:uuid], r[:title]) do
      {:ok, token} ->
        token

      :error ->
        cleaned = r[:title] |> Kernel.to_string() |> String.replace(["|", "]"], " ")

        case Mentions.Token.to_string(kind, r[:type], r[:uuid], cleaned) do
          {:ok, token} -> token
          :error -> nil
        end
    end
  end

  attr :field, Phoenix.HTML.FormField, default: nil
  attr :label, :string, default: nil
  attr :id, :string, default: nil
  attr :name, :string, default: nil
  attr :value, :string, default: nil
  attr :rows, :integer, default: 4
  attr :class, :any, default: nil
  attr :placeholder, :string, default: nil
  attr :rest, :global, include: ~w(required maxlength phx-debounce)

  @doc """
  A textarea that offers `@` and `#` as you type.

  Identical to a plain textarea in every other way, and identical to one
  entirely when JavaScript is off — the hook is the only difference, and
  what it inserts is text the field could have held anyway. That is the
  whole reason the token format is what it is.
  """
  def mention_input(assigns) do
    assigns =
      assigns
      |> assign_new(:resolved_id, fn ->
        assigns[:id] || (assigns[:field] && assigns.field.id) || "pk-mention-input"
      end)
      |> assign_new(:resolved_name, fn ->
        assigns[:name] || (assigns[:field] && assigns.field.name)
      end)
      |> assign_new(:resolved_value, fn ->
        assigns[:value] ||
          (assigns[:field] && Form.normalize_value("textarea", assigns.field.value))
      end)

    ~H"""
    <%!-- Label markup tracks `<.translatable_field>` and `<.input>`: a plain
         font-semibold span, with no `fieldset` wrapper shrinking it to
         0.75rem. These two components render side by side in the same forms
         and were identical before the label sweep. --%>
    <div class="flex flex-col gap-1">
      <label :if={@label} for={@resolved_id} class="label">
        <span class="font-semibold">{@label}</span>
      </label>
      <textarea
        id={@resolved_id}
        name={@resolved_name}
        rows={@rows}
        phx-hook="MentionInput"
        placeholder={@placeholder}
        class={["textarea w-full", @class]}
        {@rest}
      >{@resolved_value}</textarea>
      <p class="text-xs opacity-50">
        {gettext("Type @ to mention someone, # to link a record.")}
      </p>
    </div>
    """
  end

  attr :request, :any, default: nil

  @doc """
  The "ask for access" dialog. Renders nothing until a redacted mention is
  clicked.

  Deliberately says nothing about WHAT is being requested beyond its kind —
  the whole point of the redaction is that the reader does not learn the
  title, and a dialog headed with it would undo that in the one place they
  are most likely to read.
  """
  def access_request_dialog(assigns) do
    ~H"""
    <dialog :if={@request} open class="modal modal-open">
      <div class="modal-box max-w-md">
        <h3 class="text-lg font-bold">{gettext("Request access")}</h3>
        <p class="mt-1 text-sm opacity-70">
          {gettext(
            "You don't have access to this %{kind}. Ask the people who own it, and say why if it helps.",
            kind: @request.type
          )}
        </p>

        <form phx-submit="pk_access_request_submit" class="mt-4 flex flex-col gap-3">
          <label class="fieldset">
            <span class="fieldset-legend text-xs opacity-70 mb-1">{gettext("Note (optional)")}</span>
            <textarea
              name="note"
              rows="3"
              maxlength="500"
              class="textarea"
              placeholder={gettext("What do you need it for?")}
            ></textarea>
          </label>

          <div class="modal-action">
            <button type="button" phx-click="pk_access_request_close" class="btn btn-ghost btn-sm">
              {gettext("Cancel")}
            </button>
            <button
              type="submit"
              class="btn btn-primary btn-sm"
              phx-disable-with={gettext("Sending…")}
            >
              {gettext("Send request")}
            </button>
          </div>
        </form>
      </div>
      <button
        type="button"
        phx-click="pk_access_request_close"
        class="modal-backdrop"
        aria-label={gettext("Close")}
      ></button>
    </dialog>
    """
  end
end
