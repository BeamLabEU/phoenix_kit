defmodule PhoenixKit.ScheduledJobs.Handler do
  @moduledoc """
  Behaviour for scheduled job handlers.

  Implement this behaviour to create handlers for different types of scheduled jobs.
  The scheduler will dynamically load and call handlers based on the `handler_module`
  stored in the scheduled job record.

  ## Example Implementation

      defmodule MyApp.Posts.ScheduledPostHandler do
        @behaviour PhoenixKit.ScheduledJobs.Handler

        @impl true
        def job_type, do: "publish_post"

        @impl true
        def resource_type, do: "post"

        @impl true
        def execute(post_uuid, _args) do
          case MyApp.Posts.get_post(post_uuid) do
            nil -> {:error, :not_found}
            post -> MyApp.Posts.publish_post(post)
          end
        end
      end

  ## Callbacks

  - `job_type/0` - Returns a unique string identifying this job type (e.g., "publish_post", "send_email")
  - `resource_type/0` - Returns the type of resource this handler operates on (e.g., "post", "email")
  - `execute/2` - Executes the job. Receives the resource_uuid and args map. Returns `:ok` or `{:ok, result}` on success, `{:error, reason}` on failure.

  ## Return Values

  The `execute/2` callback should return:
  - `:ok` - Job completed successfully
  - `{:ok, result}` - Job completed successfully with a result (logged but not stored)
  - `{:error, reason}` - Job failed, will be retried if attempts < max_attempts

  ## Registration

  Handlers don't need to be explicitly registered. The scheduler dynamically loads
  the handler module from the job record and calls the execute function.
  """

  @doc """
  Returns the job type identifier for this handler.

  This should be a unique string that identifies the type of job.
  Examples: "publish_post", "send_email", "send_notification"
  """
  @callback job_type() :: String.t()

  @doc """
  Returns the resource type this handler operates on.

  This should match the `resource_type` field in the scheduled job record.
  Examples: "post", "email", "notification"
  """
  @callback resource_type() :: String.t()

  @doc """
  Executes the scheduled job.

  ## Parameters

  - `resource_uuid` - The UUID of the target resource
  - `args` - A map of additional arguments stored with the job

  ## Returns

  - `:ok` - Job completed successfully
  - `{:ok, result}` - Job completed successfully with additional result data
  - `{:error, reason}` - Job failed (will be retried if attempts < max_attempts)
  """
  @callback execute(resource_uuid :: binary(), args :: map()) ::
              :ok | {:ok, any()} | {:error, any()}
end
