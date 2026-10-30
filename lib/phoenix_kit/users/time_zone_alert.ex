defmodule PhoenixKit.Users.TimeZoneAlert do
  @moduledoc """
  Notices when someone is browsing from a timezone their account does not use,
  and tells them once.

  The browser is the only party that knows where a person actually is, so the
  `TimezoneDetector` hook reports its IANA zone from every authenticated page.
  This module decides whether that is worth saying anything about.

  ## What counts as a mismatch

  Only a difference that would put the wrong clock time on screen:

    * Zones in the **same behaviour group** are not a mismatch.
      `Europe/Tallinn` and `Europe/Helsinki` never disagree, in any season, so
      an account set to one while browsing from the other is fine and silent.
    * A **legacy numeric offset** is always worth replacing. Even when it is
      right today it cannot follow the next daylight-saving change, which is
      the defect the identifiers were introduced to fix.

  ## Telling them once

  A notification fires at most once per detected zone, remembered in the user's
  `custom_fields`. Someone who travels for a week gets one notification on
  arrival, not one per page view — and one more when they get home, because
  that is a different zone from the one last alerted about.

  The activity is logged with **no actor**: nobody did this, the system
  observed it. That also matters mechanically, since
  `Notifications.maybe_create_from_activity/1` skips fan-out when the actor is
  the target, and here the target is the only person involved.
  """

  require Logger

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.TimeZone

  @alerted_zone_key "timezone_alert_zone"

  @doc """
  Records what the browser reported and notifies if it disagrees with the
  account. Returns `:ok` regardless — this is a background courtesy, never
  something that should break the page that triggered it.
  """
  @spec observe(map() | nil, String.t() | any()) :: :ok
  def observe(%{managed_by_members: true}, _detected), do: :ok

  def observe(%{uuid: uuid} = user, detected) when is_binary(uuid) and is_binary(detected) do
    if TimeZone.identifier?(detected) and mismatch?(user, detected) do
      notify(user, detected)
    end

    :ok
  rescue
    error ->
      Logger.warning("[TimeZoneAlert] observe failed: #{Exception.message(error)}")
      :ok
  end

  def observe(_user, _detected), do: :ok

  @doc """
  Whether `detected` disagrees with what `user` has saved.
  """
  @spec mismatch?(map(), String.t()) :: boolean()
  def mismatch?(user, detected) do
    case Map.get(user, :user_timezone) do
      # No preference: whatever the site default is, the person never chose it,
      # so there is nothing of theirs to contradict.
      blank when blank in [nil, ""] -> false
      saved -> TimeZone.legacy_offset?(saved) or not TimeZone.same_group?(saved, detected)
    end
  end

  defp notify(user, detected) do
    if already_alerted?(user, detected) do
      :ok
    else
      remember(user, detected)
      log_activity(user, detected)
    end
  end

  defp already_alerted?(user, detected),
    do: Auth.get_user_field(user, @alerted_zone_key) == detected

  defp remember(user, detected) do
    # Internal bookkeeping, not something to surface in the admin's Custom
    # Fields list — same treatment as the editor palette. An atomic JSONB
    # merge, never a replace of the whole map: `user` here is the socket's
    # struct, which may predate a preference another tab wrote since, and a
    # replace would silently restore the stale copy of every other key.
    Auth.merge_user_custom_fields(user, %{@alerted_zone_key => detected},
      ensure_definitions: false,
      broadcast: false
    )
  end

  defp log_activity(user, detected) do
    PhoenixKit.Activity.log(%{
      action: "user.timezone_mismatch",
      module: "users",
      mode: "auto",
      actor_uuid: nil,
      target_uuid: user.uuid,
      resource_type: "user",
      resource_uuid: user.uuid,
      metadata: %{
        "detected_timezone" => detected,
        "saved_timezone" => Map.get(user, :user_timezone)
      }
    })

    :ok
  end
end
