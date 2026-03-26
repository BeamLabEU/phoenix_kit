defmodule PhoenixKitWeb.AdminEditHelper do
  @moduledoc """
  Universal admin edit URL helper.
  Assigns admin_edit_url and admin_edit_label to conn/socket if user is admin.
  Works with both Plug.Conn (controllers) and Phoenix.LiveView.Socket (LiveViews).
  """
  alias PhoenixKit.Users.Auth.Scope

  @doc """
  Assigns `:admin_edit_url` and `:admin_edit_label` if the current user is an admin.
  Returns conn/socket unchanged for non-admins or unauthenticated users.
  """
  def assign_admin_edit(conn_or_socket, path, label \\ "Edit")

  def assign_admin_edit(%Plug.Conn{} = conn, path, label) do
    if admin?(conn.assigns[:phoenix_kit_current_scope]) do
      conn
      |> Plug.Conn.assign(:admin_edit_url, path)
      |> Plug.Conn.assign(:admin_edit_label, label)
    else
      conn
    end
  end

  def assign_admin_edit(%Phoenix.LiveView.Socket{} = socket, path, label) do
    if admin?(socket.assigns[:phoenix_kit_current_scope]) do
      socket
      |> Phoenix.Component.assign(:admin_edit_url, path)
      |> Phoenix.Component.assign(:admin_edit_label, label)
    else
      socket
    end
  end

  defp admin?(scope), do: scope != nil and Scope.admin?(scope)
end
