# Your App as a Module

Several of PhoenixKit's hooks are callbacks of the `PhoenixKit.Module`
behaviour rather than config keys: what to clean up when an account is
deleted, which notification types exist, which Oban jobs run on a schedule,
which tables point at stored files, and which tabs to add to the profile
settings page. Feature packages such as `phoenix_kit_posts` implement them.
**Your application can implement them too**, and that is usually less work
than rebuilding them by hand: your own notification-preferences table, your own
GenServer timers, or a cleanup script you only discover you needed when the
first account is deleted and your tables keep its rows.

## Quick start

```elixir
# lib/my_app/kit.ex
defmodule MyApp.Kit do
  use PhoenixKit.Module

  # The five required callbacks. A host feature is normally always on, so
  # enabled?/0 can simply answer true and the toggles can do nothing.
  @impl true
  def module_key, do: "my_app"

  @impl true
  def module_name, do: "My App"

  @impl true
  def enabled?, do: true

  @impl true
  def enable_system, do: :ok

  @impl true
  def disable_system, do: :ok

  # Then only the hooks you need — see below.
  @impl true
  def before_user_delete(user_uuid) do
    MyApp.Accounts.delete_everything_owned_by(user_uuid)
  end
end
```

**You don't need to register it.** `use PhoenixKit.Module` stores a marker in the
compiled `.beam`, and `PhoenixKit.ModuleDiscovery` scans every application on
the code path whose `.app` file lists `:phoenix_kit`. Your app's `.app` lists it,
because Mix adds every runtime dependency to `applications`. Listing the module
explicitly still works and does no harm. It is also the fallback when a scan
can't see the module (for example, a module that lives in an app without a
`:phoenix_kit` dependency):

```elixir
# config/config.exs
config :phoenix_kit, modules: [MyApp.Kit]
```

The module shows up on the admin Modules page like any other module. Keep the
module key unique. It shares a namespace with every installed PhoenixKit module.

## The hooks hosts reach for most

Every callback is documented on `PhoenixKit.Module`. These are the ones a host
application usually wants:

| Callback | What it does for you |
|---|---|
| `before_user_delete/1` | Called with the user's uuid **before** the user row is deleted, while related rows still exist. Use it for cleanup the database cascades can't do: rows without a foreign key to the users table, files on disk, external accounts. Best-effort: a hook that raises is logged and does not stop the deletion. Called for every discovered module, enabled or not. |
| `notification_types/0` | Notification types (and sub-types) your app sends. They appear on each user's notification preferences page, and PhoenixKit stores and honours the user's choices. You don't need a preferences table of your own. |
| `oban_crons/0` | `{cron, worker}` pairs. `mix phoenix_kit.install` and `mix phoenix_kit.update` write any entries missing from your Oban crontab, as they do for core's own workers. See `PhoenixKit.ObanCrons`. Declare the queue in `oban_queues/0` or use a core queue. |
| `file_references/0` | `{table, condition}` pairs naming the tables that point at stored files, so the storage orphan check never treats a file your app uses as an orphan. |
| `profile_settings_tabs/0` | Extra tabs on the user's profile settings page, rendered by your own LiveView. |
| `children/0` | Processes to start under PhoenixKit's supervisor. |
| `admin_tabs/0` | Admin sidebar tabs. For a host, `config :phoenix_kit, :admin_dashboard_tabs` is the lighter option. See [Custom Admin Pages](custom-admin-pages.md). |

## Keeping preferences in `custom_fields`

If your per-user preferences live in the user's `custom_fields` JSONB column,
write them with `PhoenixKit.Users.Auth.merge_user_custom_fields/3` and remove
them with `PhoenixKit.Users.Auth.delete_user_custom_field/3`. Do **not** write
them with `update_user_custom_fields/3`. It replaces the whole column with the
map you pass, and PhoenixKit keeps its own keys in that column
(`notification_preferences`, `preferred_locale`, `start_page`). A struct loaded
in `mount/3` and saved later through the replace function silently rolls those
keys back. Prefix your own keys (for example `"my_app_theme"`) so they can
never collide with core's or another module's.

## Reference files

- `lib/phoenix_kit/module.ex`: the behaviour, with every callback documented
- `lib/phoenix_kit/module_discovery.ex`: how modules are found
- `lib/phoenix_kit/module_registry.ex`: the runtime registry
- `lib/phoenix_kit/oban_crons.ex`: how `oban_crons/0` reaches your config
