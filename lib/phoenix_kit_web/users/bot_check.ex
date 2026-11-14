defmodule PhoenixKitWeb.Users.BotCheck do
  @moduledoc """
  The Turnstile check of a public form's submit, for a LiveView.

      def handle_event("save", params, socket) do
        case BotCheck.run(socket, params, socket.assigns[:ip_address]) do
          {:ok, socket} -> ...the submit as before...
          {:error, socket} -> {:noreply, socket}
        end
      end

  Goes FIRST: before the rate limiter (a refused bot must not spend an
  address's or the site's allowance) and before any lookup. `{:error, socket}`
  carries the flash; the answer is the same whatever address was typed.

  Either way the widget is told to start over: a token is good for one
  verification, so a submit that stays on the page (a validation error) needs a
  new one. With Turnstile off this does nothing at all.
  """
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Phoenix.LiveView, only: [push_event: 3, put_flash: 3]

  alias PhoenixKit.Users.Turnstile

  @reset_event "phoenix_kit:turnstile_reset"

  @spec run(Phoenix.LiveView.Socket.t(), map(), String.t() | nil) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:error, Phoenix.LiveView.Socket.t()}
  def run(socket, params, ip_address) when is_map(params) do
    if Turnstile.enabled?() do
      case Turnstile.verify(params[Turnstile.response_field()], ip_address) do
        :ok ->
          {:ok, push_event(socket, @reset_event, %{})}

        {:error, :missing} ->
          # No reset: the challenge may still be running.
          {:error,
           put_flash(
             socket,
             :error,
             gettext(
               "Please wait for the verification to finish, then try again. If you do not see it, reload the page."
             )
           )}

        {:error, :rejected} ->
          {:error,
           socket
           |> push_event(@reset_event, %{})
           |> put_flash(:error, gettext("The verification did not succeed. Please try again."))}
      end
    else
      {:ok, socket}
    end
  end
end
