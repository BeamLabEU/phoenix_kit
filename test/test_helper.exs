# Test helper for PhoenixKit test suite

# Refuse before anything else touches the database — see
# PhoenixKit.Test.LiveDatabaseGuard's moduledoc for why this exists
# alongside (not instead of) an external wrapper script some hosts
# already use for the same purpose.
db_name =
  Application.get_env(:phoenix_kit, PhoenixKit.Test.Repo)[:database] || "phoenix_kit_test"

PhoenixKit.Test.LiveDatabaseGuard.check!(db_name)

# One classified connection attempt, with the repo's OWN credentials and
# transport, before anything starts the pool.
#
# This replaces a `psql -lqt` listing. That check asked the wrong question: it
# ran as the shell's user over a unix socket, so it reported "the database is
# there" and told us nothing about whether the CONFIGURED role could reach it
# over TCP. When it could not, the answer arrived minutes later as a pool
# checkout timeout that reads like a flaky test.
db_check =
  case PhoenixKit.TestSupport.PostgresPreflight.check(
         Application.get_env(:phoenix_kit, PhoenixKit.Test.Repo, [])
       ) do
    :ok ->
      :exists

    {:error, _reason, message} ->
      IO.puts(:stderr, "\n" <> message)
      :not_found
  end

# Started before the repo block: the Owner seed below promotes through
# `ensure_first_user_is_owner/1`, which broadcasts on the internal pubsub —
# without the manager running, the seed raises and the rescue silently
# excludes the whole integration half as "no database".
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n⚠  Cannot reach test database "#{db_name}" — integration tests will be excluded.
       The reason is printed above.
    """)

    false
  else
    try do
      {:ok, _} = PhoenixKit.Test.Repo.start_link()

      # Use `ensure_current/2` — it picks up newly-shipped Vxxx
      # migrations on every boot. The previous fixed-version
      # migration-file approach was vulnerable to the
      # outer-Ecto-tracking staleness trap; see
      # `PhoenixKit.Migration.ensure_current/2` moduledoc for the bug
      # story.
      PhoenixKit.Migration.ensure_current(PhoenixKit.Test.Repo, log: false)

      # What the boot sweep gives the Admin role (`Permissions.auto_grant_new_keys_to_admin/0`
      # runs at application start, not here): the two sub-permissions of `media`, so an Admin
      # in a test sees everything in Media and opens the storage screens, as in production.
      # Committed once; idempotent.
      case PhoenixKit.Users.Roles.get_role_by_name("Admin") do
        %{uuid: admin_uuid} ->
          for key <- ~w(media.view_all media.manage),
              do: PhoenixKit.Users.Permissions.grant_permission(admin_uuid, key)

        _ ->
          :ok
      end

      # A COMMITTED Owner, seeded before the sandbox goes manual. Without one,
      # every async test's first `register_user` sees a committed owner-count
      # of 0 and takes FOR NO KEY UPDATE on the one committed Owner role row
      # (Roles.ensure_first_user_is_owner/1), holding it to test end — an
      # app-wide registration convoy queuing every concurrent test on a single
      # tuple lock, and the standing suspect for the suite's rare 40P01.
      # With an Owner already committed, that path short-circuits unlocked.
      #
      # Idempotent so a reused database does not grow a second seed. Tests
      # asserting first-user bootstrap semantics delete this seed's role
      # assignment inside their own sandbox transaction, where the count goes
      # to 0 for them alone.
      # Seeded by direct insert + the bootstrap promoter, NOT register_user:
      # registration consults the rate limiter, whose ETS table is not alive
      # at helper time, and its raise here would trip the rescue below and
      # silently exclude the whole integration half as "no database".
      if PhoenixKit.Users.Roles.count_active_owners() == 0 do
        seed =
          PhoenixKit.Users.Auth.get_user_by_email("seed-owner@phoenixkit.test") ||
            %PhoenixKit.Users.Auth.User{}
            |> Ecto.Changeset.change(%{
              email: "seed-owner@phoenixkit.test",
              hashed_password: Bcrypt.hash_pwd_salt("SeedOwnerPassword123!"),
              confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
              is_active: true
            })
            |> PhoenixKit.Test.Repo.insert!()

        {:ok, _} = PhoenixKit.Users.Roles.ensure_first_user_is_owner(seed)
      end

      Ecto.Adapters.SQL.Sandbox.mode(PhoenixKit.Test.Repo, :manual)
      true
    rescue
      e ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Run `mix test.setup` to create the test database.
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           Run `mix test.setup` to create the test database.
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit, :test_repo_available, repo_available)

# With no reachable database, `PhoenixKit.Test.Repo` still STARTS — only its
# connections fail — so `Settings.repo_available?/0` stays true and every
# settings read on the unit half queues against a dead pool for ~4s before
# falling back to its default. That is the documented "unit tests still need
# PostgreSQL" trap in AGENTS.md; it makes a DB-less `mix test` take minutes and
# times out anything that resolves a path (`Routes.path/1` reads two settings).
#
# `:update_mode` is consulted by `PhoenixKit.Settings`, where it short-circuits
# the query to `nil` — the same value the 4s stall eventually produces, so the
# outcome of every read is unchanged; only its cost is. It is also read by mix
# tasks and the supervisor (neither runs here), `Dashboard.Registry`, and
# `ModuleRegistry.run_all_legacy_migrations/0`, which does nothing in it —
# a test of that function sets `update_mode: false` itself. `:repo` stays
# configured.
#
# Applied only in the run where the database is already known to be unusable —
# when it is reachable nothing here changes.
unless repo_available do
  Application.put_env(:phoenix_kit, :update_mode, true)
end

# Start minimal services needed for tests
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])
{:ok, _pid} = PhoenixKit.Users.RateLimiter.Backend.start_link([])

# Start the LV endpoint once for the whole test run. `PhoenixKitWeb.ConnCase`
# previously did this per-test via `start_supervised`, but that ties the
# endpoint's lifetime to a single test pid — when an async test finishes,
# ExUnit tears down its supervisor and any concurrent test loses the
# `PhoenixKitWeb.Endpoint` ETS config table mid-request, surfacing as
# `:ets.lookup(PhoenixKitWeb.Endpoint, :secret_key_base)` ArgumentErrors.
# A single Application-level start avoids that race entirely.
case Process.whereis(PhoenixKitWeb.Endpoint) do
  nil -> {:ok, _} = PhoenixKitWeb.Endpoint.start_link()
  _pid -> :ok
end

# Tests that `CREATE ROLE` inside their sandbox transaction need CREATEROLE
# (or superuser). A shared or managed test database often grants neither;
# excluding them is visible in the summary, where a failure would read as a
# regression.
can_create_role =
  repo_available and
    Ecto.Adapters.SQL.Sandbox.unboxed_run(PhoenixKit.Test.Repo, fn ->
      match?(
        %{rows: [[true]]},
        PhoenixKit.Test.Repo.query!(
          "SELECT rolcreaterole OR rolsuper FROM pg_roles WHERE rolname = current_user",
          [],
          log: false
        )
      )
    end)

if repo_available and not can_create_role do
  IO.puts("""
  \n⚠  The test database role lacks CREATEROLE — tests tagged :requires_createrole are excluded.
  """)
end

# Exclude integration tests when DB is not available
exclude =
  cond do
    not repo_available -> [:integration]
    not can_create_role -> [:requires_createrole]
    true -> []
  end

ExUnit.start(exclude: exclude)
