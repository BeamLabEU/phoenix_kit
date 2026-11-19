defmodule PhoenixKit.API.OAuth.ConnectedMail do
  @moduledoc """
  The email that tells a person an application was connected to their account
  (`app_connected` in the email catalog): sent once, when the connection is activated, that is
  when the authorization code is exchanged (`PhoenixKit.API.OAuth.Exchange`), for a connection
  that works at once and for one that waits for an Owner's approval alike.

  `start/2` is called after the exchange has committed and returns at once: the code lives 60
  seconds and the mail server can be slow, so the delivery runs under `PhoenixKit.TaskSupervisor`
  and nothing about it can fail the exchange. There is no retry: a mail lost to a failure or a
  restart is lost, and the connection stays in the activity feed (`oauth.grant_created`). A
  failure is logged by the kind of the exception only, never with a value of the request.

  The mail says what the application called itself (the name as the person saw it on the consent
  screen, with control characters already removed), the host the application's answers go to, the
  rights by module, the expiry, the time, the address of the consent and the state (works, or
  waits for approval). It has no token and no code. It is not sent to an account that may not
  get automated mail (`PhoenixKit.Users.Auth.unsolicited_mail_allowed?/1`), and there is no switch
  to turn it off.
  """

  require Logger

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.LogSafe
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.RedirectUri
  alias PhoenixKit.API.OAuth.Scopes
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserNotifier

  # The inline mode exists only in a build compiled with the test seams (`config :phoenix_kit,
  # oauth_test_seams: true`), like the other OAuth seams.
  @test_seams Application.compile_env(:phoenix_kit, :oauth_test_seams, false)

  @doc """
  Starts the delivery for `grant`, whose code was exchanged with `redirect_uri`, and returns
  without waiting for it. Never raises.

  The delivery is a task of `PhoenixKit.TaskSupervisor` (`{:ok, pid}`), or `:error` when none
  could be started. Without that supervisor (a bare test run) the task is linked to no one but
  keeps the callers of this process, so a sandboxed database and the test mailer find their
  owner. In a build compiled with the test seams, `config :phoenix_kit, :oauth_connected_mail,
  :inline` runs the delivery in the calling process instead (`:ok`): the suites of the exchange
  set it, so that no task outlives a test that holds a database connection.
  """
  @spec start(Grant.t(), String.t()) :: :ok | {:ok, pid()} | :error
  def start(%Grant{} = grant, redirect_uri) when is_binary(redirect_uri) do
    run = fn -> safely(fn -> deliver(grant, redirect_uri) end) end

    if inline?() do
      run.()
      :ok
    else
      start_task(run)
    end
  end

  defp inline?,
    do: @test_seams and Application.get_env(:phoenix_kit, :oauth_connected_mail) == :inline

  defp start_task(run) do
    started =
      case Process.whereis(PhoenixKit.TaskSupervisor) do
        nil -> Task.start(run)
        supervisor -> Task.Supervisor.start_child(supervisor, run)
      end

    case started do
      {:ok, pid} -> {:ok, pid}
      _failed -> :error
    end
  catch
    :exit, _reason -> :error
  end

  @doc """
  Sends the mail now, in the calling process: `{:ok, email}`, `{:ok, %{suppressed: true}}` for a
  person who may not get it, or `{:error, reason}` (`:no_owner` when the person is gone).
  """
  @spec deliver(Grant.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def deliver(%Grant{user_uuid: user_uuid} = grant, redirect_uri) do
    case repo().get(User, user_uuid) do
      %User{} = user -> UserNotifier.deliver_app_connected(user, attrs(grant, redirect_uri))
      nil -> {:error, :no_owner}
    end
  end

  defp attrs(%Grant{} = grant, redirect_uri) do
    %{
      name: app_name(grant),
      host: host(redirect_uri),
      rights: rights(grant.scopes),
      expires_at: grant.expires_at,
      at: grant.activated_at || DateTime.truncate(DateTime.utc_now(), :second),
      ip: grant.created_ip,
      waiting?: Grants.awaiting?(grant)
    }
  end

  # The name the person saw on the consent screen: the hidden key of the grant was named after it.
  # A key that does not carry it falls back to what the client calls itself now.
  defp app_name(%Grant{key_uuid: key_uuid, client_uuid: client_uuid}) do
    case Keys.get_key(key_uuid) do
      %Key{} = key -> Keys.pinned_oauth_name(key) || client_name(repo().get(Client, client_uuid))
      nil -> client_name(repo().get(Client, client_uuid))
    end
  end

  defp client_name(%Client{client_name: name}) when is_binary(name) and name != "", do: name
  defp client_name(%Client{client_id: client_id}), do: client_id
  defp client_name(nil), do: nil

  # The host the answers go to, with its port when it is not the scheme's own.
  defp host(redirect_uri) do
    case RedirectUri.address(redirect_uri) do
      %{host: host, port: nil} -> host
      %{host: host, port: port} -> "#{host}:#{port}"
      nil -> nil
    end
  end

  # One entry per module, whether the grant reads there, changes there, or both.
  defp rights(scopes) do
    scopes
    |> Scopes.describe()
    |> Enum.group_by(& &1.module_key)
    |> Enum.map(fn {key, entries} ->
      %{
        key: key,
        name: hd(entries).module_name,
        read?: Enum.any?(entries, & &1.read?),
        write?: Enum.any?(entries, &(not &1.read?))
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  # The mail is a courtesy: whatever goes wrong here ends in the log, by kind, and nowhere else.
  defp safely(fun) do
    case fun.() do
      {:error, reason} ->
        Logger.warning("OAuth connection mail not sent: " <> LogSafe.shape(reason))

      _sent ->
        :ok
    end
  rescue
    error -> Logger.warning("OAuth connection mail failed: " <> LogSafe.exception_label(error))
  catch
    kind, _reason -> Logger.warning("OAuth connection mail failed: #{kind}")
  end

  defp repo, do: RepoHelper.repo()
end
