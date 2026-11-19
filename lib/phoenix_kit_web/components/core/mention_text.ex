defmodule PhoenixKitWeb.Components.Core.MentionText do
  @moduledoc """
  Renders free text that may contain `@` and `#` mentions, resolved for the
  person looking at it.

      <.mention_text text={@comment.content} scope={@phoenix_kit_current_scope} />

  Each mention becomes one of three things, and which one is a permission
  decision made per viewer, at render:

    * **a link** — they may open it, so they get the live title and a real
      deep-link. The title is re-resolved rather than taken from the text,
      so a renamed record reads correctly.

    * **plain text** — it is gone, or its module was uninstalled. They get
      the label the author saw, unlinked. This is the case that justifies
      keeping the label in the text at all.

    * **the title plus a lock** — it exists and they may not open it. The
      sentence still reads as the thing it names; the lock says it isn't
      theirs, and clicking asks the owners for access. No link.

  The third case shows a LIVE title by default, on the view that a record's
  name is rarely the secret — the access is. Installs where the name IS
  sensitive turn on `mentions_redact_titles`, and a forbidden mention then
  falls back to the label the author stored, so a record renamed after the
  fact never shows its new name to someone who cannot open it.

  ## Wiring the request-access click

  The chip pushes `"pk_request_access"` with `type` and `uuid`. Handle it
  yourself, or get the handler and the dialog for free:

      use PhoenixKit.Mentions.Live

  …then render `<.access_request_dialog request={@pk_access_request} />`
  somewhere in the template — the handler only stages the request; the
  dialog is what asks for the note and submits it.

  Without either, the click is inert — the chip still renders and still
  tells the reader why they cannot see the thing.

  ## No JavaScript

  Everything here is server-rendered. The typeahead that *inserts* mentions
  is a progressive enhancement; reading them has never needed JS.
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.UserInfo, only: [user_avatar: 1]

  alias PhoenixKit.Mentions
  alias PhoenixKit.Mentions.Token
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  attr :text, :string, default: nil
  attr :scope, :any, default: nil, doc: "the viewer — decides what resolves"
  attr :class, :any, default: nil

  attr :allow_request, :boolean,
    default: true,
    doc: "offer \"ask for access\" on a redacted mention"

  attr :withhold_titles, :boolean,
    default: false,
    doc: """
    For PUBLIC surfaces. A mention the viewer may not see renders with no
    title and no stored label at all, rather than the usual name-plus-lock.
    Independent of the `mentions_redact_titles` setting, which is a
    judgement about internal readers and says nothing about the open web.
    """

  attr :rest, :global

  def mention_text(assigns) do
    assigns =
      assign_new(assigns, :pieces, fn ->
        %{text: text, scope: scope} = assigns

        context =
          Mentions.context(text,
            user_uuid: user_uuid(scope),
            scope: scope,
            withhold_titles: assigns.withhold_titles
          )

        text
        |> Token.split()
        |> Enum.map(fn
          %Token{} = token ->
            {token, Map.get(context, {token.type, token.uuid}, %{state: :missing})}

          piece ->
            piece
        end)
      end)

    # The people a readable @ mention names, in one read: their chip shows
    # their face (the boss, 2026-11-18: "a mentioned user shown as a chip").
    assigns = assign_new(assigns, :mentioned_users, fn -> mentioned_users(assigns.pieces) end)

    ~H"""
    <span class={@class} {@rest}><%= for piece <- @pieces do %>
      <.piece
        piece={piece}
        allow_request={@allow_request}
        users={@mentioned_users}
      />
    <% end %></span>
    """
  end

  defp mentioned_users(pieces) do
    pieces
    |> Enum.flat_map(fn
      {%Token{kind: :user, uuid: uuid}, %{state: :ok}} when is_binary(uuid) -> [uuid]
      _ -> []
    end)
    |> Enum.uniq()
    |> case do
      [] -> %{}
      uuids -> uuids |> Auth.get_users_by_uuids() |> Map.new(&{&1.uuid, &1})
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  # One rendered fragment: either a run of ordinary text or a resolved
  # mention. Kept as its own component so the three mention states are
  # readable side by side rather than nested in a comprehension.
  attr :piece, :any, required: true
  attr :allow_request, :boolean, required: true
  attr :users, :map, default: %{}

  defp piece(%{piece: text} = assigns) when is_binary(text) do
    ~H"{@piece}"
  end

  # A person: a chip with their face and name, a link where the mention
  # resolves to one (public surfaces drop the path).
  defp piece(%{piece: {%Token{kind: :user, uuid: uuid} = token, %{state: :ok} = info}} = assigns)
       when is_map_key(assigns.users, uuid) do
    assigns = assign(assigns, token: token, info: info, person: Map.fetch!(assigns.users, uuid))

    ~H"""
    <.link
      :if={@info[:path]}
      navigate={href(@info)}
      class="inline-flex items-center gap-1 align-middle rounded-full bg-base-200 hover:bg-base-300 py-0.5 pl-0.5 pr-2 font-medium no-underline"
      data-mention-user={@token.uuid}
    ><.user_avatar user={@person} name={@info[:title]} size="xs" />{@info[:title]}</.link><span
      :if={is_nil(@info[:path])}
      class="inline-flex items-center gap-1 align-middle rounded-full bg-base-200 py-0.5 pl-0.5 pr-2 font-medium"
      data-mention-user={@token.uuid}
    ><.user_avatar user={@person} name={@info[:title]} size="xs" />{@info[:title]}</span>
    """
  end

  defp piece(%{piece: {%Token{} = token, %{state: :ok} = info}} = assigns) do
    assigns = assign(assigns, token: token, info: info)

    ~H"""
    <.link
      :if={@info[:path]}
      navigate={href(@info)}
      class="link link-primary font-medium no-underline hover:underline"
    >{prefix_for(@token)}{@info[:title]}</.link><span
      :if={is_nil(@info[:path])}
      class="font-medium"
    >{prefix_for(@token)}{@info[:title]}</span>
    """
  end

  # Deleted, or the module that owned it is no longer installed. The
  # author's words survive; the link does not.
  defp piece(%{piece: {%Token{} = token, %{state: :missing}}} = assigns) do
    assigns = assign(assigns, token: token)

    ~H"""
    <span class="opacity-70" title={gettext("No longer available")}>{prefix_for(@token)}{@token.label}</span>
    """
  end

  # A public surface asked us to withhold, and this one points outside what
  # the page may show. No title, no label, no link — the reader learns that
  # something is referenced and nothing about what it is. The sentence keeps
  # its noun slot, which is why this is not simply deleted: "blocked by" with
  # nothing after it reads as a bug.
  defp piece(%{piece: {%Token{}, %{state: :private}}} = assigns) do
    ~H"""
    <span
      title={gettext("Not shown on this page")}
      class="inline-flex items-baseline gap-0.5 opacity-60"
    >{gettext("private item")}<.icon name="hero-lock-closed" class="w-3 h-3 shrink-0 self-center" /></span>
    """
  end

  # The title, plus a lock. The sentence stays readable — a mention blanked
  # to "No access" leaves a hole where a noun should be — and the lock says
  # plainly that this one isn't yours to open. No href: knowing what it is
  # called is not the same as being let in.
  #
  # `title` comes from the context, which falls back to the author's stored
  # label when the record is gone or the install has redaction turned on.
  defp piece(%{piece: {%Token{} = token, %{state: :forbidden} = info}} = assigns) do
    assigns = assign(assigns, token: token, label: info[:title] || token.label)

    ~H"""
    <button
      :if={@allow_request}
      type="button"
      phx-click="pk_request_access"
      phx-value-type={@token.type}
      phx-value-uuid={@token.uuid}
      title={gettext("You don't have access — click to request it")}
      class="inline-flex items-baseline gap-0.5 cursor-pointer opacity-70 hover:opacity-100 underline decoration-dotted underline-offset-2"
    >{prefix_for(@token)}{@label}<.icon
      name="hero-lock-closed"
      class="w-3 h-3 shrink-0 self-center"
    /></button><span
      :if={not @allow_request}
      title={gettext("You don't have access to this")}
      class="inline-flex items-baseline gap-0.5 opacity-70"
    >{prefix_for(@token)}{@label}<.icon
      name="hero-lock-closed"
      class="w-3 h-3 shrink-0 self-center"
    /></span>
    """
  end

  # An `@` keeps its sigil so a ping reads as a ping; a `#` does not,
  # because the record's own title is the better label in a sentence.
  defp prefix_for(%Token{kind: :user}), do: "@"
  defp prefix_for(_), do: ""

  defp href(%{path: path, prefixed: false}), do: path
  defp href(%{path: path}), do: Routes.path(path)

  defp user_uuid(%{user: %{uuid: uuid}}), do: uuid
  defp user_uuid(_), do: nil
end
