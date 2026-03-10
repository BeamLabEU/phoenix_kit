defmodule PhoenixKit.Modules.Newsletters.Workers.DeliveryWorker do
  @moduledoc """
  Oban worker for sending a single broadcast email to one recipient.

  ## Job Arguments

  - `delivery_uuid` - UUID of the Delivery record
  - `broadcast_uuid` - UUID of the Broadcast record

  ## Queue Configuration

  Add to your Oban config (concurrency controls rate limiting):

      config :my_app, Oban,
        queues: [newsletters_delivery: 10]

  The `newsletters_rate_limit` setting (default: 14 emails/sec) maps to queue concurrency.
  Parent app should read `Settings.get_setting("newsletters_rate_limit", "10")` and apply to Oban queue config.
  """

  use Oban.Worker,
    queue: :newsletters_delivery,
    max_attempts: 3,
    unique: [period: :infinity, keys: [:delivery_uuid], states: :incomplete]

  require Logger

  alias PhoenixKit.Modules.Emails.Template
  alias PhoenixKit.Modules.Newsletters
  alias PhoenixKit.Modules.Newsletters.Delivery
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"delivery_uuid" => delivery_uuid, "broadcast_uuid" => broadcast_uuid}
      }) do
    with {:ok, delivery} <- get_delivery(delivery_uuid),
         {:ok, broadcast} <- get_broadcast(broadcast_uuid),
         {:ok, user} <- get_user(delivery.user_uuid),
         {:ok, html_body, text_body} <- render_email(broadcast, user),
         {:ok, _result} <- send_email(broadcast, user, html_body, text_body) do
      Newsletters.update_delivery_status(delivery, "sent", %{
        sent_at: UtilsDate.utc_now(),
        message_id: nil
      })

      update_broadcast_counter(broadcast_uuid, :sent_count)

      :ok
    else
      {:error, reason} ->
        Logger.error("DeliveryWorker: Failed delivery #{delivery_uuid}: #{inspect(reason)}")
        handle_failure(delivery_uuid, broadcast_uuid, reason)
        {:error, inspect(reason)}
    end
  end

  defp get_delivery(uuid) do
    case repo().get(Delivery, uuid) do
      nil -> {:error, :delivery_not_found}
      delivery -> {:ok, delivery}
    end
  end

  defp get_broadcast(uuid) do
    {:ok, Newsletters.get_broadcast!(uuid)}
  rescue
    Ecto.NoResultsError -> {:error, :broadcast_not_found}
  end

  defp get_user(user_uuid) do
    case repo().get(PhoenixKit.Users.Auth.User, user_uuid) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp render_email(broadcast, user) do
    variables = build_variables(broadcast, user)
    html = substitute_variables(broadcast.html_body || "", variables)
    text = substitute_variables(broadcast.text_body || "", variables)

    html = maybe_apply_template(html, broadcast)

    {:ok, html, text}
  end

  defp build_variables(broadcast, user) do
    token_data = %{user_uuid: user.uuid, list_uuid: broadcast.list_uuid}

    unsubscribe_token =
      Phoenix.Token.sign(PhoenixKitWeb.Endpoint, "unsubscribe", token_data)

    unsubscribe_url =
      Routes.url("/newsletters/unsubscribe?token=#{unsubscribe_token}")

    %{
      "name" => user.username || user.email,
      "email" => user.email,
      "unsubscribe_url" => unsubscribe_url
    }
  end

  defp substitute_variables(content, variables) do
    Enum.reduce(variables, content, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end

  defp maybe_apply_template(content, %{template_uuid: nil}), do: content

  defp maybe_apply_template(content, %{template_uuid: template_uuid}) do
    case repo().get(Template, template_uuid) do
      nil -> content
      template -> String.replace(template.html_body, "{{content}}", content)
    end
  end

  defp send_email(broadcast, user, html_body, text_body) do
    from_email = PhoenixKit.Settings.get_setting("from_email", "noreply@example.com")
    from_name = PhoenixKit.Settings.get_setting("from_name", "Newsletter")

    Swoosh.Email.new()
    |> Swoosh.Email.to(user.email)
    |> Swoosh.Email.from({from_name, from_email})
    |> Swoosh.Email.subject(broadcast.subject)
    |> Swoosh.Email.html_body(html_body)
    |> Swoosh.Email.text_body(text_body)
    |> PhoenixKit.Mailer.deliver_email()
  end

  defp handle_failure(delivery_uuid, broadcast_uuid, reason) do
    case get_delivery(delivery_uuid) do
      {:ok, delivery} ->
        Newsletters.update_delivery_status(delivery, "failed", %{
          error: inspect(reason)
        })

        update_broadcast_counter(broadcast_uuid, :bounced_count)

      _ ->
        :ok
    end
  end

  defp update_broadcast_counter(broadcast_uuid, field) do
    import Ecto.Query

    PhoenixKit.Modules.Newsletters.Broadcast
    |> where([b], b.uuid == ^broadcast_uuid)
    |> repo().update_all(inc: [{field, 1}])
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
