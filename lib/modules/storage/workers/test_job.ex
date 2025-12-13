defmodule PhoenixKit.Modules.Storage.TestJob do
  @moduledoc """
  Simple test job to verify Oban is working
  """
  use Oban.Worker, queue: :file_processing

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message" => message}}) do
    Logger.info("TestJob: SUCCESS! Message: #{message}")
    :ok
  end
end
