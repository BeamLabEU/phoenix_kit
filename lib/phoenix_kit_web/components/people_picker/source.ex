defmodule PhoenixKitWeb.Components.PeoplePicker.Source do
  @moduledoc """
  Where `PhoenixKitWeb.Components.PeoplePicker` finds the people it offers.

  A source groups what can be picked (core's users, or a module's people,
  teams and departments) and answers four questions: which groups to show
  when the picker opens, a page of one group or of a search, what one
  picked key is, and — optionally — what this viewer picked lately. Core
  ships `PhoenixKitWeb.Components.PeoplePicker.UserSource` (the site's
  accounts); a module passes its own (`source={MyModule.PickerSource}`).

  Every callback gets `ctx`: the picker's `source_opts` map (whatever the
  caller passed, e.g. `%{project_uuid: …}`) plus `:viewer_uuid` and
  `:locale` (the request's Gettext locale). Callbacks must not raise into
  the picker; a failing read is shown as an empty list.

  ## Rows

  A row is a map:

      %{
        kind: "person",            # the source's own word; with uuid it is the key
        uuid: "019…",
        label: "Anna Kask",
        sublabel: "anna@example.com",  # optional, a second line
        icon: "hero-user",         # optional heroicon, when there is no face
        user: %User{} | nil,       # optional: drawn with core's `user_avatar`
        name: "Anna Kask",         # optional: the name the avatar's letters come from
        faces: [%User{}],          # optional: a group's members, drawn as a stack
        member?: true              # optional: indented under the group before it
      }

  A key is `{kind, uuid}`, both strings. What the picker posts and sends to
  its parent is a list of keys.
  """

  @type ctx :: %{required(:viewer_uuid) => String.t() | nil, optional(atom()) => term()}
  @type key :: {String.t(), String.t()}
  @type row :: %{
          required(:kind) => String.t(),
          required(:uuid) => String.t(),
          required(:label) => String.t(),
          optional(:sublabel) => String.t() | nil,
          optional(:icon) => String.t() | nil,
          optional(:user) => map() | nil,
          optional(:name) => String.t() | nil,
          optional(:faces) => [map()],
          optional(:member?) => boolean()
        }
  @type group :: %{key: String.t(), label: String.t()}
  @type view :: {:group, String.t()} | {:search, String.t()}

  @doc """
  The groups the picker opens on, in order (e.g. Teams, Departments,
  People). Each is shown with its first few rows and a "Browse more" when
  there are more.
  """
  @callback groups(ctx()) :: [group()]

  @doc """
  One page of a group (`{:group, key}`) or of a search (`{:search, text}`,
  the text trimmed, at most 100 characters). `cursor` is nil for the first
  page, else what the previous page returned; the answer's second element
  is the next cursor, nil when there is no more.
  """
  @callback page(view(), cursor :: term() | nil, limit :: pos_integer(), ctx()) ::
              {[row()], next :: term() | nil}

  @doc """
  The row of one key, for a chip — and the check that a pick names
  something real: a pick the source cannot describe picks nothing (a
  forged event). nil when it no longer exists.
  """
  @callback describe(key(), ctx()) :: row() | nil

  @doc """
  What picking `key` means. `{:ok, key}` adds that key (it may differ:
  an account picked as the person record behind it); `{:confirm, prompt}`
  asks first — `prompt` is `%{title:, text:, confirm:}` — and calls
  `confirm/2` on Yes; `{:error, message}` shows the message instead.
  Optional: without it a pick adds the key as it is.
  """
  @callback pick(key(), ctx()) ::
              {:ok, key()}
              | {:confirm, %{title: String.t(), text: String.t(), confirm: String.t()}}
              | {:error, String.t()}

  @doc "The Yes of a `{:confirm, _}` pick. Optional, required when `pick/2` asks."
  @callback confirm(key(), ctx()) :: {:ok, key()} | {:error, String.t()}

  @doc """
  The viewer's own entry, for the "Add me" button (nil: no button).
  Optional.
  """
  @callback me(ctx()) :: key() | nil

  @doc """
  The viewer's recent picks, newest first, at most `limit` rows. Optional;
  without it the picker shows no Recent chips.
  """
  @callback recent(limit :: pos_integer(), ctx()) :: [row()]

  @doc "Remembers a pick as the viewer's (for `recent/2`). Optional."
  @callback remember(key(), ctx()) :: :ok

  @optional_callbacks pick: 2, confirm: 2, me: 1, recent: 2, remember: 2
end
