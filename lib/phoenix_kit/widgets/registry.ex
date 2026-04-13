# lib/phoenix_kit/widgets/registry.ex

defmodule PhoenixKit.Widgets.Registry do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def register(module_name, widgets) do
    GenServer.cast(__MODULE__, {:register, module_name, widgets})
  end

  def get_all do
    GenServer.call(__MODULE__, :get_all)
  end

  def init(state) do
    {:ok, state}
  end

  def handle_cast({:register, module, widgets}, state) do
    {:noreply, Map.put(state, module, widgets)}
  end

  def handle_call(:get_all, _from, state) do
    {:reply, state, state}
  end
end
