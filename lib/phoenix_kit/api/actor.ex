defmodule PhoenixKit.API.Actor do
  @moduledoc """
  Who is calling the API: a key (with its owner and effective scopes), a person's live
  browser session (in process, `PhoenixKit.API.Executor.execute_as/5`) or an anonymous
  public caller.

    * `kind` - `:key` for a verified bearer key, `:user` for a live session,
      `:anonymous` for a public caller.
    * `key_uuid`, `key_prefix` - the key, when there is one (`nil` for `:user`).
    * `user_uuid` - the key's owner, or the session's user.
    * `scopes` - the key's effective scopes (its own, filtered by the owner's live
      permissions), or the scopes the session's scope holds
      (`PhoenixKit.API.Keys.held_scopes_of/1`).
    * `scope` - the `PhoenixKit.Users.Auth.Scope` those scopes were computed from: the
      owner's `Scope.for_user(owner, narrow: false)` for a key, the session's narrowed
      scope for `:user`, `nil` for an anonymous caller. Handlers read it as `ctx.scope`.
    * `personal` - the key is a personal one (`PhoenixKit.API.Keys.Key`'s `personal`): its
      owner's right to personal keys was checked when the actor was built.
      `PhoenixKit.API.Keys.effective_scopes/1` checks it again for an old actor. `false` for
      every other actor.
    * `requires_approval` - every write call of the key (not a read, not a `dry_run`)
      waits for a human, dangerous or not.
    * `client_token_hash` - the hash of the client token an anonymous public caller sent in the
      field its tool declares (`PhoenixKit.API.Tool`'s `:client_token`); `nil` when the tool
      declares none or the caller sent none. The raw token is never kept.
    * `ip` - the address the request came from, as a string.

  The default is the least-privileged value: anonymous, no scopes, not personal, no approval.

  `inspect/1` leaves `scope` out: it holds the user (email, name), and the actor sits in
  `conn.assigns` on every API request, where error reports and debug pages print it.
  """

  @derive {Inspect, except: [:scope]}
  defstruct kind: :anonymous,
            key_uuid: nil,
            key_prefix: nil,
            user_uuid: nil,
            scopes: [],
            scope: nil,
            personal: false,
            requires_approval: false,
            client_token_hash: nil,
            ip: nil

  @type t :: %__MODULE__{
          kind: :key | :user | :anonymous,
          key_uuid: String.t() | nil,
          key_prefix: String.t() | nil,
          user_uuid: String.t() | nil,
          scopes: [String.t()],
          scope: PhoenixKit.Users.Auth.Scope.t() | nil,
          personal: boolean(),
          requires_approval: boolean(),
          client_token_hash: String.t() | nil,
          ip: String.t() | nil
        }
end
