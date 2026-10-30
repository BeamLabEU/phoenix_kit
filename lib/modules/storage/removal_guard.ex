defmodule PhoenixKit.Modules.Storage.RemovalGuard do
  @moduledoc """
  A host's say in whether the media browser may remove a file.

  A file can be in use somewhere the media library knows nothing about — an
  order's attachment, a page's picture. A module of the host that knows where
  implements this behaviour, and the media browser asks it before it sends a
  file to the trash or deletes it for good.

      config :phoenix_kit, :file_removal_guard, MyApp.FileRemovalGuard

  The setting reaches EVERY media browser, the Media page of the core
  included; one browser takes another module with its `removal_guard`
  attribute, or `removal_guard={false}` to go without. With no module the
  browser behaves as it always did, with its own browser confirmations.

  ## What is asked, and when

  Only when a file actually disappears: a file sent to the trash or deleted
  (`Storage.removal_plan/2` says which). A file merely taken out of one folder
  while another keeps it (unlinked, or re-homed there) is not asked about.

  `places/2` answers where the files are in use. With no place, the browser
  asks the person to confirm ("Move 3 files to trash?"). With places, it
  refuses and lists them; when the module has `release/2` and `release_label/1`
  answers a text for this person, the list has a button with that text, which
  frees the files (for instance "Unlink everywhere") and asks again.

  `ctx` is `%{scope: scope, action: action, folder_uuid: uuid | nil}`:

    * `scope` — the `PhoenixKit.Users.Auth.Scope` of the person acting. A host
      narrowed to the person's active role passes that scope to the browser as
      `phoenix_kit_current_scope`; without it the scope is built from
      `phoenix_kit_current_user`;
    * `action` — `:trash_file`, `:delete_file`, `:delete_selected`,
      `:trash_folder`, `:delete_folder` or `:empty_trash`;
    * `folder_uuid` — the folder the action is taken in or on, `nil` outside
      any folder.

  A place is `%{file_uuid, label, detail, href}`. `label: nil` means a place
  the person may not see: the browser says "not available to you" and shows
  neither `detail` nor `href`. `href` is opened in a new tab.

  ## Fails closed

  A guard that raises, exits, or answers something else than the shapes above
  removes nothing: the person is told the files could not be checked, and the
  log names the module and the exception, never the request. A `release/2`
  that answers `{:error, message}` shows `message` when it is a string, a
  generic text otherwise.

  A call that takes longer than `config :phoenix_kit,
  :file_removal_guard_timeout` (milliseconds, default 5000) is stopped and
  fails closed the same way, and so does a call whose process dies. The
  calls run in a process of their own, not linked to the page's: it has the
  page's Gettext locale and logger metadata, and the database sandbox of a
  test reaches it through `$callers`. Process-dictionary state of the page
  (anything else a callback might read from it) is not there.

  An answer that names a file the browser did not ask about is a contract
  break and fails closed too (uuids are compared in lower case).

  The page waits for the answer: every call holds the person's page for as
  long as it takes, up to the timeout (a confirmation asks twice, a release
  three times). Keep `places/2` fast — an indexed lookup, not a scan. The
  process is not linked to the page: if the page goes away mid-call, the
  callback still runs to its end (a `release/2` may still commit).

  ## The window that remains

  The browser asks, then removes. What the dialog showed is what is removed
  (the files named, nothing found later), but a file attached between
  `places/2` and the DELETE is still removed. A host for which that matters
  keeps the reference as a foreign key with `ON DELETE RESTRICT` (or the
  equivalent check in its own transaction): the database, not this callback,
  is the last word.

  ## What it does not cover

  The guard stands in the media browser's events. It is not asked by the
  daily `Storage.prune_trash/1`, by a host's own background jobs, by the API
  or the console, nor by "Delete all orphaned" (orphans are in no folder by
  definition). Code that deletes files by other means asks the host's own
  rules.
  """

  alias PhoenixKit.Users.Auth.Scope

  @type action ::
          :trash_file
          | :delete_file
          | :delete_selected
          | :trash_folder
          | :delete_folder
          | :empty_trash

  @type ctx :: %{scope: Scope.t(), action: action(), folder_uuid: String.t() | nil}

  @type place :: %{
          file_uuid: String.t(),
          label: String.t() | nil,
          detail: String.t() | nil,
          href: String.t() | nil
        }

  @callback places([String.t()], ctx()) :: [place()]
  @callback release([String.t()], ctx()) :: :ok | {:error, term()}
  @callback release_label(ctx()) :: String.t() | nil

  @optional_callbacks release: 2, release_label: 1

  @doc "The module set with `config :phoenix_kit, :file_removal_guard`, or nil."
  @spec configured() :: module() | nil
  def configured do
    case Application.get_env(:phoenix_kit, :file_removal_guard) do
      module when is_atom(module) and module not in [nil, false, true] -> module
      _ -> nil
    end
  end
end
