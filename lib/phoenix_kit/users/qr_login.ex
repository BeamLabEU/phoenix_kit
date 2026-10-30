defmodule PhoenixKit.Users.QrLogin do
  @moduledoc """
  QR device-handoff login ("scan to sign in") for PhoenixKit.

  This is the PhoenixKit-side integration of the [`keyfob`](https://hex.pm/packages/keyfob)
  library. Keyfob owns the rendezvous — request lifecycle, expiry,
  single-use enforcement, the secret split, PubSub signaling. This module
  wires it into PhoenixKit: the internal PubSub, the `qr_login_enabled`
  setting, device-metadata extraction for the confirm screen, and activity
  logging on approval.

  ## The flow

  1. A signed-out browser opens `/users/qr-login`
     (`PhoenixKitWeb.Users.QrLogin`) and a QR encoding the phone-confirm URL
     is shown. The LiveView waits.
  2. The user's already-signed-in phone scans it, opens the confirm URL
     (`PhoenixKitWeb.Users.QrLoginConfirm`), reviews the requesting device,
     and taps Approve — which calls `approve/2` with the phone user's uuid.
  3. Approval mints a one-time login token delivered over PubSub only to
     the waiting browser, which navigates to the completion controller
     (`PhoenixKitWeb.Users.QrLoginComplete`).
  4. The controller calls `consume/1` (`{:ok, user_uuid}`, exactly once) and
     logs that user in with PhoenixKit's own session machinery.

  Approval always happens on the trusted (phone) device; the browser gets
  nothing until the phone approves. See `keyfob`'s docs for the threat
  model (QR-jacking, the secret split).

  All keyfob calls are routed through PhoenixKit's internal PubSub
  (`#{inspect(:phoenix_kit_internal_pubsub)}`) so the desktop LiveView and
  the phone confirm LiveView rendezvous on the same bus. The default
  `Keyfob.Store.ETS` (started in `PhoenixKit.Supervisor`) holds requests.
  """

  require Logger

  alias Phoenix.LiveView
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Geolocation
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.UserAgent

  # PhoenixKit's internal PubSub, started by `PhoenixKit.PubSub.Manager`.
  @pubsub :phoenix_kit_internal_pubsub

  @doc """
  Whether QR device-handoff login is enabled (setting `qr_login_enabled`,
  default `false`).
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Settings.get_boolean_setting("qr_login_enabled", false)

  @doc "The PubSub name every keyfob call in this integration uses."
  @spec pubsub() :: atom()
  def pubsub, do: @pubsub

  @doc "Shared keyfob options — routes every call through PhoenixKit's internal PubSub."
  @spec keyfob_opts() :: keyword()
  def keyfob_opts, do: [pubsub: @pubsub]

  ## ── Thin keyfob wrappers (so call sites never repeat the opts) ─────────

  @doc "See `Keyfob.create_request/1`. Merges the shared PubSub option."
  def create_request(opts \\ []), do: Keyfob.create_request(Keyword.merge(keyfob_opts(), opts))

  @doc "See `Keyfob.peek/2`."
  def peek(token), do: Keyfob.peek(token, keyfob_opts())

  @doc "See `Keyfob.approve/3`. `user_ref` is the approving user's uuid."
  def approve(token, user_ref) do
    case Auth.get_user(user_ref) do
      %Auth.User{managed_by_members: true} -> {:error, :not_allowed}
      %Auth.User{api_only: true} -> {:error, :not_allowed}
      %Auth.User{is_active: true} -> Keyfob.approve(token, user_ref, keyfob_opts())
      _ -> {:error, :not_allowed}
    end
  end

  @doc "See `Keyfob.deny/2`."
  def deny(token), do: Keyfob.deny(token, keyfob_opts())

  @doc "See `Keyfob.consume/2`. Returns `{:ok, user_uuid}` exactly once."
  def consume(token), do: Keyfob.consume(token, keyfob_opts())

  @doc "See `Keyfob.subscribe/2`."
  def subscribe(token), do: Keyfob.subscribe(token, keyfob_opts())

  @doc "See `Keyfob.unsubscribe/2`."
  def unsubscribe(token), do: Keyfob.unsubscribe(token, keyfob_opts())

  ## ── Device metadata for the confirm screen ────────────────────────────

  @doc """
  Extracts a device-description map from the requesting browser's connected
  socket, shown verbatim on the phone confirm screen so the human can
  recognise (or reject) the sign-in.

  Keys: `:browser`, `:os`, `:ip`, `:location` — any of which may be absent
  when the underlying connect-info (or geo lookup) is unavailable — plus
  `:requested_at`, an absolute UTC timestamp of when the code was minted so
  the approver can sanity-check "did I just do this?".

  The geo lookup is a best-effort, timeout-bounded call on the requesting
  browser's IP (same machinery registration/login-alerts already use); it
  runs at QR-mint time so the location is baked into the request the phone
  later reads.
  """
  @spec device_meta(LiveView.Socket.t()) :: map()
  def device_meta(socket) do
    ua = LiveView.get_connect_info(socket, :user_agent)
    # extract_from_socket/1 returns the literal "unknown" when peer_data is
    # unavailable (proxies, some transports) — treat that (and blanks) as
    # absent so the confirm screen omits the IP row instead of showing a
    # bare "unknown", and so we don't feed a placeholder into the geo lookup.
    ip = present_ip(IpAddress.extract_from_socket(socket))

    %{requested_at: requested_at()}
    |> put_present(:browser, UserAgent.browser(ua))
    |> put_present(:os, UserAgent.os(ua))
    |> put_present(:ip, ip)
    |> put_present(:location, ip && location_for(ip))
  end

  # Geolocation.lookup_location/1 tries two providers sequentially, each with
  # its own 5s HTTP timeout — up to ~10s in the worst case. That's fine for
  # the registration/login-alert paths (fire-and-forget), but here it runs
  # inline in the QR page's connected mount, blocking the code the page
  # exists to show. Bound it well below that so a slow/unreachable geo API
  # degrades to "no location" instead of stalling the mint.
  @lookup_timeout_ms 1_500

  @doc """
  Formats a best-effort `"City, Country"` (or just `"Country"`) string for
  an IP, or `nil` when the lookup fails, is unavailable, or is still running
  after #{@lookup_timeout_ms}ms. Never raises — a geo backend hiccup must
  not crash (or stall) the QR mint that shows the code.
  """
  @spec location_for(String.t() | nil) :: String.t() | nil
  def location_for(ip) when is_binary(ip) do
    # async_nolink (not Task.async): the lookup must never be able to crash
    # the calling LiveView via a link, only ever resolve to nil on failure.
    task =
      Task.Supervisor.async_nolink(PhoenixKit.TaskSupervisor, fn ->
        Geolocation.lookup_location(ip)
      end)

    result =
      case Task.yield(task, @lookup_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, lookup_result} -> lookup_result
        _ -> :timeout
      end

    case result do
      {:ok, %{"city" => city, "country" => country}}
      when is_binary(city) and city != "" and is_binary(country) ->
        "#{city}, #{country}"

      {:ok, %{"country" => country}} when is_binary(country) and country != "" ->
        country

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def location_for(_), do: nil

  ## ── Activity logging ───────────────────────────────────────────────────

  @doc """
  Records a `user.qr_login_approved` activity for the approving user.

  Actor and target are the same user (they approved their own sign-in), so
  no notification is generated — this is an audit-trail entry only. Errors
  are swallowed: a logging failure must never block the sign-in.
  """
  @spec log_approval(map(), map()) :: :ok
  def log_approval(user, meta \\ %{}) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      try do
        PhoenixKit.Activity.log(%{
          action: "user.qr_login_approved",
          module: "users",
          mode: "manual",
          actor_uuid: user.uuid,
          target_uuid: user.uuid,
          resource_type: "user",
          resource_uuid: user.uuid,
          metadata: %{"actor_role" => "user", "device" => meta}
        })
      rescue
        error ->
          Logger.warning("[PhoenixKit.QrLogin] activity log failed: #{inspect(error)}")
      end
    end

    :ok
  end

  ## ── Internals ──────────────────────────────────────────────────────────

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # Placeholder IPs from `IpAddress.extract_from_socket/1` (unreadable peer
  # data) count as "no IP" so they neither render nor drive a geo lookup.
  defp present_ip(ip) when ip in [nil, "", "unknown"], do: nil
  defp present_ip(ip), do: ip

  defp requested_at do
    Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M UTC")
  end
end
