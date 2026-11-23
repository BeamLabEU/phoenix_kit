defmodule PhoenixKit.Test.HandoffStubModule do
  @moduledoc """
  A stand-in feature module with per-session state (a guest cart in the session), for the
  handoff tests. Registered with `PhoenixKit.ModuleRegistry` by the test.

  The handoff runs every hook in a task of its own, so each call reports itself to the process
  that started the request (the first of `$callers`, which under `Phoenix.ConnTest` is the test
  process) with a message.
  """

  def module_key, do: "handoff_stub"
  def module_name, do: "Handoff stub"
  def enabled?, do: true

  def handoff_snapshot(context) do
    send(caller(), {:handoff_snapshot, context})

    case context.session["stub_cart"] do
      nil -> nil
      cart -> %{cart: cart, atom_key: :value}
    end
  end

  def handoff_apply(context, payload) do
    send(caller(), {:handoff_apply, context, payload})

    {:ok,
     %{
       notices: ["Your cart came along."],
       moved: 1,
       cookies: [
         {"stub_cart_id", payload["cart"], [http_only: true, max_age: 600, unsafe_option: true]}
       ]
     }}
  end

  defp caller, do: List.first(Process.get(:"$callers", [])) || self()
end
