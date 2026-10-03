defmodule PhoenixKit.Supervisor do
  @moduledoc """
  Supervisor for all PhoenixKit workers.
  """
  use Supervisor

  alias PhoenixKit.Modules.Languages

  alias PhoenixKit.Modules.Storage.Workers.{
    ChecksumBackfillJob,
    LocationBackfillJob,
    ReconcileJob
  }

  alias PhoenixKit.Users.Permissions

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    update_mode = Application.get_env(:phoenix_kit, :update_mode, false)
    children = build_children(update_mode)
    Supervisor.init(children, strategy: :one_for_one)
  end

  # Minimal set of children needed when running mix phoenix_kit.update.
  # Skips Dashboard.Registry, OAuthConfigLoader, module workers, and presence
  # so the update task only needs 1-2 DB connections for migrations.
  # Settings cache starts with NO warmer — all Settings functions return nil/%{}
  # in update_mode anyway, so warming would just spam warnings every 10 s.
  defp build_children(true = _update_mode) do
    [
      PhoenixKit.PubSub.Manager,
      {PhoenixKit.Cache.Registry, []},
      PhoenixKit.ModuleRegistry,
      Supervisor.child_spec(
        {PhoenixKit.Cache, name: :settings},
        id: :settings_cache
      ),
      PhoenixKit.Users.RateLimiter.Backend
    ]
  end

  # Full set of children for normal application operation.
  defp build_children(false = _update_mode) do
    [
      PhoenixKit.PubSub.Manager,
      PhoenixKit.Admin.SimplePresence,
      # Keyfob QR device-handoff login store (ETS) — holds pending sign-in
      # requests and one-time login tokens for PhoenixKit.Users.QrLogin.
      Keyfob.Store.ETS,
      {PhoenixKit.Cache.Registry, []},
      # Module registry — must start before Dashboard.Registry so module tabs are available
      PhoenixKit.ModuleRegistry,
      # Settings cache starts BEFORE Dashboard.Registry so enabled?/0 calls hit the cache
      # instead of making individual DB queries per module at startup.
      # `ttl:` bounds how long a setting written OUTSIDE this node stays invisible
      # — a `mix run` script, a second web node without distributed Erlang, a
      # console. Cache invalidation is in-process, so without it those writes were
      # never seen until a restart. Five minutes: settings are admin-rare writes,
      # so this bounds staleness without meaningfully increasing database load.
      #
      # ⚠️ This is only safe because `get_settings_cached/2` fills on miss. It did
      # not, and with no TTL nothing ever expired to expose that — the first
      # expiry wave would have left OAuth credentials and date formats reading
      # `nil` site-wide.
      Supervisor.child_spec(
        {PhoenixKit.Cache,
         name: :settings,
         sync_init: true,
         ttl: :timer.minutes(5),
         warmer: &PhoenixKit.Settings.warm_cache_data/0},
        id: :settings_cache
      ),
      # Whether a user may see a TRASHED file's variants
      # (`FileController.authorize_trashed_read/1`), for a few seconds. A Trash
      # tab renders every thumbnail through `/file/...`, and building the answer
      # is a role query plus a permission load per image — the cache turns a
      # grid's burst into one. The TTL bounds how long a revoked "media"
      # permission keeps admitting trashed thumbnails; the page already
      # rendered, and the browser's own image cache, outlast it anyway.
      Supervisor.child_spec(
        {PhoenixKit.Cache, name: :trashed_file_access, ttl: :timer.seconds(5)},
        id: :trashed_file_access_cache
      ),
      # Dashboard tab registry for user dashboard navigation.
      # Starts after settings_cache so module enabled? checks hit cache rather than DB.
      PhoenixKit.Dashboard.Registry,
      # Grant the Admin role any permission keys it has never been auto-granted
      # before (newly installed feature modules, new sub-permissions). Per-key
      # settings flags make an Owner's revocation stick across restarts. Runs
      # after ModuleRegistry (key discovery) and the settings cache (flag
      # reads); idempotent and a silent no-op when the table doesn't exist yet.
      # Modules registered at runtime (ModuleRegistry.register/1) are picked
      # up on the next boot.
      Supervisor.child_spec(
        {Task,
         fn ->
           try do
             Permissions.auto_grant_new_keys_to_admin()
             Permissions.backfill_media_sub_permissions()
           rescue
             error ->
               require Logger

               Logger.error(
                 "[PhoenixKit] Failed to auto-grant permission keys to Admin at startup: #{inspect(error)}"
               )
           end
         end},
        id: :auto_grant_admin_permissions
      ),
      # Once per boot: say which declared Oban queues this node does not run
      # (see PhoenixKit.ObanQueues). Delayed, because the host usually starts
      # Oban after PhoenixKit; best-effort and silent when Oban is absent, in
      # testing mode, or deliberately runs no queues on this node.
      Supervisor.child_spec(
        {Task,
         fn ->
           Process.sleep(:timer.seconds(10))
           PhoenixKit.ObanQueues.warn_about_missing_queues()
         end},
        id: :oban_queue_check
      ),
      # Once per boot: queue the storage location backfill (V204) while any
      # stored object has no location row, and the checksum backfill while
      # any file still has the upload API's old MD5 checksum, and the storage
      # reconciler (V205) while any file is not where its library's profile
      # wants it. Delayed for the same reason as the queue check above; the
      # daily trash prune queues them too, and only one pending run of each
      # exists at a time.
      Supervisor.child_spec(
        {Task,
         fn ->
           Process.sleep(:timer.seconds(30))
           LocationBackfillJob.maybe_enqueue()
           ChecksumBackfillJob.maybe_enqueue()
           ReconcileJob.maybe_enqueue()
         end},
        id: :storage_location_backfill
      ),
      # Normalize legacy admin_languages setting into unified languages_config
      # Runs once after settings cache is warmed; idempotent no-op if already migrated
      Supervisor.child_spec(
        {Task,
         fn ->
           try do
             Languages.normalize_language_settings()
             # Languages is core, not a registered module, so the registry's
             # boot-time `migrate_legacy/0` sweep no longer reaches it.
             Languages.migrate_legacy()
           rescue
             error ->
               require Logger

               Logger.error(
                 "[PhoenixKit] Failed to normalize language settings at startup: #{inspect(error)}"
               )
           catch
             :exit, reason ->
               require Logger

               Logger.error(
                 "[PhoenixKit] Language settings migration exited at startup: #{inspect(reason)}"
               )
           end
         end},
        id: :normalize_languages
      ),
      # Rate limiter backend MUST be started before any authentication requests
      PhoenixKit.Users.RateLimiter.Backend,
      # Task supervisor for fire-and-forget background work (e.g. stale fixer)
      {Task.Supervisor, name: PhoenixKit.TaskSupervisor},
      # OAuth config loader - now guaranteed to have critical settings in cache
      PhoenixKit.Workers.OAuthConfigLoader
    ] ++
      PhoenixKit.ModuleRegistry.static_children()
  end
end
