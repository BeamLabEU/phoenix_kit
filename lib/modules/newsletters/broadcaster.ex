defmodule PhoenixKit.Modules.Mailing.Broadcaster do
  @moduledoc """
  Orchestrates broadcast sending: paginates list members, creates Delivery
  records and Oban jobs in batches.
  """

  require Logger

  import Ecto.Query

  alias PhoenixKit.Modules.Mailing
  alias PhoenixKit.Modules.Mailing.{Broadcast, Delivery, ListMember}
  alias PhoenixKit.Modules.Mailing.Workers.DeliveryWorker
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @batch_size 500

  @doc """
  Starts sending a broadcast. Transitions status to `sending`,
  creates delivery records, and enqueues Oban jobs.
  """
  def send(%Broadcast{status: "draft"} = broadcast) do
    do_send(broadcast)
  end

  def send(%Broadcast{status: "scheduled"} = broadcast) do
    do_send(broadcast)
  end

  def send(%Broadcast{status: status}) do
    {:error, {:invalid_status, status}}
  end

  defp do_send(broadcast) do
    repo = repo()

    # Render markdown to HTML before sending
    {:ok, html, _warnings} = Earmark.as_html(broadcast.markdown_body || "")
    text = strip_html(html)

    {:ok, broadcast} =
      Mailing.update_broadcast(broadcast, %{
        status: "sending",
        html_body: html,
        text_body: text,
        sent_at: UtilsDate.utc_now()
      })

    # Count total active members
    total = Mailing.count_active_members(broadcast.list_uuid)
    {:ok, broadcast} = Mailing.update_broadcast(broadcast, %{total_recipients: total})

    # Process in batches using transaction-wrapped stream
    repo.transaction(fn ->
      stream_active_members(broadcast.list_uuid)
      |> Stream.chunk_every(@batch_size)
      |> Enum.each(fn batch ->
        process_batch(broadcast, batch, repo)
      end)
    end)

    Logger.info("Broadcaster: Enqueued #{total} deliveries for broadcast #{broadcast.uuid}")
    {:ok, broadcast}
  end

  defp stream_active_members(list_uuid) do
    ListMember
    |> where([m], m.list_uuid == ^list_uuid and m.status == "active")
    |> select([m], m.user_uuid)
    |> repo().stream()
  end

  defp process_batch(broadcast, user_uuids, repo) do
    now = UtilsDate.utc_now()

    deliveries =
      Enum.map(user_uuids, fn user_uuid ->
        %{
          uuid: UUIDv7.generate(),
          broadcast_uuid: broadcast.uuid,
          user_uuid: user_uuid,
          status: "pending",
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, inserted} = repo.insert_all(Delivery, deliveries, returning: [:uuid])

    jobs =
      Enum.map(inserted, fn %{uuid: delivery_uuid} ->
        DeliveryWorker.new(%{
          delivery_uuid: delivery_uuid,
          broadcast_uuid: broadcast.uuid
        })
      end)

    Oban.insert_all(jobs)
  end

  defp strip_html(html) do
    html
    |> String.replace(~r/<br\s*\/?>/, "\n")
    |> String.replace(~r/<\/p>/, "\n\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
