defmodule PhoenixKit.Notifications.Push.GroupWorker do
  @moduledoc """
  One push per user per grouping window (`PhoenixKit.Notifications.Push`).

  `schedule/2` inserts a job due in N seconds, unique per user while one is
  waiting: notices queued meanwhile join it. When it runs it takes every
  waiting notice, builds the one push ("New notification", "3 notifications
  pending") and hands it to `PhoenixKit.Notifications.Push.SendWorker`, one
  job per device. Nothing waiting (a second job raced it): nothing sent.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 3,
    unique: [keys: [:user_uuid], states: [:available, :scheduled], period: 600]

  import Ecto.Query

  alias PhoenixKit.Notifications.Push
  alias PhoenixKit.Notifications.Push.{Binding, SendWorker}
  alias PhoenixKit.RepoHelper

  @doc "Makes sure a push for `user_uuid` is due within `seconds`."
  @spec schedule(String.t(), pos_integer()) :: :ok | {:error, term()}
  def schedule(user_uuid, seconds) do
    %{"user_uuid" => user_uuid}
    |> new(schedule_in: seconds)
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, _} = error -> error
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_uuid" => user_uuid}}) when is_binary(user_uuid) do
    case Push.take_pending(user_uuid) do
      {:ok, payload} ->
        json = Jason.encode!(payload)

        from(b in Binding, where: b.user_uuid == ^user_uuid, select: b.installation_uuid)
        |> RepoHelper.repo().all()
        |> Enum.each(fn installation_uuid ->
          SendWorker.enqueue(installation_uuid, user_uuid, json, Push.topic(user_uuid))
        end)

        :ok

      :none ->
        :ok
    end
  end

  def perform(_job), do: :ok
end

defmodule PhoenixKit.Notifications.Push.SendWorker do
  @moduledoc """
  One push to one device. Retried with Oban's backoff when the push service
  is busy or unreachable (429, 5xx, network); a device the service says is
  gone (404/410) is removed with its bindings; a key mismatch (401/403) is
  logged and kept — never a reason to delete someone's devices. The device
  must still be bound to the account when the job runs: a logout in between
  stops it.
  """

  use Oban.Worker, queue: :notifications, max_attempts: 5

  require Logger

  import Ecto.Query

  alias PhoenixKit.Notifications.Push
  alias PhoenixKit.Notifications.Push.{Binding, Installation, WebPush}
  alias PhoenixKit.RepoHelper

  @doc false
  def enqueue(installation_uuid, user_uuid, payload_json, topic) do
    %{
      "installation_uuid" => installation_uuid,
      "user_uuid" => user_uuid,
      "payload" => payload_json,
      "topic" => topic
    }
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{
            "installation_uuid" => installation_uuid,
            "user_uuid" => user_uuid,
            "payload" => payload
          } = args
      }) do
    repo = RepoHelper.repo()

    with %Installation{} = installation <- repo.get(Installation, installation_uuid),
         true <-
           repo.exists?(
             from(b in Binding,
               where: b.installation_uuid == ^installation_uuid and b.user_uuid == ^user_uuid
             )
           ) do
      send_to(installation, payload, args["topic"])
    else
      _ -> :ok
    end
  end

  def perform(_job), do: :ok

  # One send to the installation as it was read (a test passes a stale one).
  @doc false
  def send_to(%Installation{} = installation, payload, topic) do
    repo = RepoHelper.repo()

    case WebPush.send(installation, payload, ttl: Push.ttl(), topic: topic) do
      :ok ->
        now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

        repo.update_all(same_subscription(installation), set: [last_success_at: now])
        :ok

      # Only the subscription this push went to: a row rotated (resubscribe)
      # while the request was out keeps its new subscription.
      {:gone, _status} ->
        repo.delete_all(same_subscription(installation))
        :ok

      {:retry, _after} ->
        {:error, :push_service_busy}

      {:error, reason} ->
        Logger.warning("[Push] a device refused the push: #{inspect(reason)}")
        :ok
    end
  end

  defp same_subscription(%Installation{uuid: uuid, endpoint_hash: hash}) do
    from(i in Installation, where: i.uuid == ^uuid and i.endpoint_hash == ^hash)
  end
end
