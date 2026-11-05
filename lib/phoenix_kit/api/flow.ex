defmodule PhoenixKit.API.Flow do
  @moduledoc """
  Steps 7 and 8 of the request flow, written as small functions over the
  executor's request state so `PhoenixKit.API.Executor.execute/4` stays a plain chain:

      ... Flow.merge_header -> validate -> Flow.split_control ->
          Flow.idempotency -> Flow.gate -> run

  Each step returns `{:ok, state}` to go on, `{:error, code, detail, context, state}`
  to refuse (the executor answers a problem document), or `{:done, state}` when the
  answer is already in `state.body` (a preview, a replay): the executor then responds
  without running the handler. `finish/1` and `release/1` are called when the
  response is sent: they store the answer under the idempotency claim, or give the
  claim up.

  The request state is the executor's map. Besides its own keys the steps read and set
  `control`, `dry_run?`, `input_hash`, `claim`, `replayed?`, `held_again?`, `store?`,
  `outcome`, `confirmation`, `preview` and `result` (the answer as a decoded map, for a
  transport that wants the map rather than the text). The executor resolves
  `request_context` once, before the gate, for every context the steps build.
  """

  require Logger

  alias PhoenixKit.API.Approvals
  alias PhoenixKit.API.Canonical
  alias PhoenixKit.API.Confirm
  alias PhoenixKit.API.ControlFields
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.FlowConfig
  alias PhoenixKit.API.Idempotency
  alias PhoenixKit.API.LogSafe
  alias PhoenixKit.API.Tool

  # --- control fields -----------------------------------------------------------

  @doc """
  The `Idempotency-Key` header of a write call becomes the `idempotency_key` field, so
  the schema validates it like the field. Both given and different, or the header sent
  twice, is a validation error. A read tool ignores the header, and so does a request
  that does not read it (`idempotency_header?: false`, the MCP transport: its key is the
  argument), and a write tool that cannot replay (`ControlFields.replay_tool?/1`).
  """
  def merge_header(%{tool: tool, input: input, conn: conn, idempotency_header?: true} = state)
      when is_map(input) do
    if ControlFields.replay_tool?(tool) do
      case Plug.Conn.get_req_header(conn, "idempotency-key") do
        [] -> {:ok, state}
        [value] -> merge_key(state, value)
        _repeated -> invalid(state, "idempotency_key", "must be sent once")
      end
    else
      {:ok, state}
    end
  end

  def merge_header(state), do: {:ok, state}

  defp merge_key(%{input: input} = state, value) do
    case Map.fetch(input, "idempotency_key") do
      :error -> {:ok, %{state | input: Map.put(input, "idempotency_key", value)}}
      {:ok, ^value} -> {:ok, state}
      {:ok, _other} -> invalid(state, "idempotency_key", "must match the Idempotency-Key header")
    end
  end

  defp invalid(state, path, message) do
    {:error, :validation_failed, "The input does not match the schema of #{state.tool.name}.",
     %{errors: [%{path: path, message: message, limit: nil, allowed: nil}]}, state}
  end

  @doc """
  Takes the control fields out of the validated input. The handler gets what is left;
  `input_hash` is computed from it, so a confirming call hashes like its preview.

  The input of a write tool must not hold a NUL character (JSON `\\u0000`): a code or an
  approval keeps the input and its preview in `jsonb`, which cannot store one, so the call
  is refused here, before anything is claimed or written.
  """
  def split_control(%{input: input, tool: tool} = state) when is_map(input) do
    {control, rest} = ControlFields.split(input)

    case nul_in(tool, rest) do
      nil ->
        {:ok,
         %{
           state
           | control: control,
             input: rest,
             dry_run?: control["dry_run"] == true,
             input_hash: Canonical.hash(tool.name, rest)
         }}

      {path, message} ->
        invalid(state, path, message)
    end
  end

  defp nul_in(tool, input) do
    if ControlFields.write_tool?(tool), do: find_nul(input, "")
  end

  # The path of the first string (or key) with a NUL character in it. Keys are cut as the
  # validator cuts them, and a key with a NUL is reported by the path of its object.
  defp find_nul(value, path) when is_binary(value) do
    if :binary.match(value, <<0>>) != :nomatch, do: {path, "must not contain a NUL character"}
  end

  defp find_nul(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.find_value(fn {element, index} -> find_nul(element, "#{path}[#{index}]") end)
  end

  defp find_nul(map, path) when is_map(map) and not is_struct(map) do
    Enum.find_value(map, fn {key, value} ->
      if find_nul(key, path),
        do: {path, "has a key with a NUL character"},
        else: find_nul(value, child_path(path, key))
    end)
  end

  defp find_nul(_other, _path), do: nil

  defp child_path(path, key) do
    segment =
      if byte_size(key) > 64, do: String.byte_slice(key, 0, 64) <> "...", else: key

    if path == "", do: segment, else: path <> "." <> segment
  end

  # --- idempotency (step 7) -----------------------------------------------------------

  @doc """
  Claims the request's `Idempotency-Key`, if it has one. A dry run never claims.
  A public call without a client token has no scope to claim in and ignores the key.
  """
  def idempotency(%{control: %{"idempotency_key" => key}, dry_run?: false} = state)
      when is_binary(key) do
    case scope_ref(state) do
      nil -> {:ok, state}
      scope_ref -> claim(state, scope_ref, key)
    end
  end

  def idempotency(state), do: {:ok, state}

  defp claim(state, scope_ref, key) do
    case Idempotency.claim(scope_ref, key, state.input_hash) do
      {:claimed, claim} ->
        {:ok, %{state | claim: claim}}

      {:replay, body} ->
        {:done,
         %{state | body: body, replayed?: true, outcome: "replayed", result: JSON.decode!(body)}}

      {:error, :in_progress} ->
        {:error, :idempotency_in_progress,
         "A request with this Idempotency-Key is still running. Retry in a moment.", %{}, state}

      {:error, :reused} ->
        {:error, :idempotency_key_reused,
         "This Idempotency-Key was used for a different request.", %{}, state}
    end
  end

  defp scope_ref(%{audience: :admin, actor: %{key_uuid: uuid}}) when is_binary(uuid), do: uuid

  defp scope_ref(%{audience: :public, actor: %{client_token_hash: hash}}) when is_binary(hash),
    do: hash

  defp scope_ref(_state), do: nil

  @doc """
  Called when the answer is sent. Stores a `200` body under the claim when it may be
  stored (`Idempotency.storable?/2`, given the tool's own credential fields), otherwise gives
  the claim up. Never raises: the handler has already run, so a store that fails (a database
  hiccup) is logged and the answer is sent anyway; the claim then runs out with its lease.
  """
  def finish(%{claim: nil}), do: :ok

  def finish(%{claim: claim, store?: true, body: body} = state) when is_binary(body) do
    guarded(fn ->
      if Idempotency.storable?(body, tool_credential_keys(state)) do
        _ = Idempotency.store(claim, body)
      else
        Idempotency.release(claim)
      end
    end)
  end

  def finish(%{claim: claim}), do: guarded(fn -> Idempotency.release(claim) end)

  defp tool_credential_keys(%{tool: %Tool{} = tool}), do: Tool.credential_keys(tool)
  defp tool_credential_keys(_state), do: []

  @doc "Called when the request is refused: gives the idempotency claim up. Never raises."
  def release(%{claim: nil}), do: :ok
  def release(%{claim: claim}), do: guarded(fn -> Idempotency.release(claim) end)

  defp guarded(fun) do
    fun.()
    :ok
  rescue
    error ->
      log_claim_failure(LogSafe.exception_label(error))
  catch
    kind, reason ->
      log_claim_failure("#{kind}: #{LogSafe.shape(reason)}")
  end

  defp log_claim_failure(what) do
    Logger.error(
      "[PhoenixKit.API] could not store or give up an Idempotency-Key claim, it stays until its lease runs out: #{what}"
    )

    :ok
  end

  # --- the danger gate (step 8) ----------------------------------------------------------

  @doc """
  Step 8. A read tool passes. `dry_run: true` runs the handler with `ctx.dry_run? == true`
  and answers the preview (no code, no approval). A write of a person's live session
  (`kind: :user`) never runs on this call, dangerous or not: it is held for the person to
  confirm (`session_flow/1`). Any other write call of a key that requires approval goes to
  the approval queue, dangerous or not, and a `confirm_token` from such a key is refused.
  For every other caller a dangerous call (`dangerous?/1`) goes through the confirmation
  flow, and any other call passes.
  """
  def gate(%{tool: tool} = state) do
    cond do
      not ControlFields.write_tool?(tool) -> {:ok, state}
      state.dry_run? -> dry_run_only(state)
      session?(state) -> session_flow(state)
      approval_key?(state) or dangerous?(state) -> confirm_flow(state)
      true -> {:ok, state}
    end
  end

  defp dry_run_only(state) do
    with {:ok, previewed} <- Executor.preview(state) do
      body = %{"executed" => false, "dry_run" => true, "preview" => previewed.preview.data}
      {:done, answer(previewed, body, "preview")}
    end
  end

  # --- what is dangerous ---------------------------------------------------------------

  defp dangerous?(%{tool: %Tool{danger: :always}}), do: true
  defp dangerous?(%{tool: %Tool{danger: nil}} = state), do: batch_danger?(state)

  defp dangerous?(%{tool: %Tool{danger: {module, function}} = tool} = state)
       when is_atom(module) and not is_nil(module) and is_atom(function) and not is_nil(function),
       do: function_danger?(tool, state) or batch_danger?(state)

  # `Tool.validate/1` refuses any other value, so this is a hand-built struct. A declaration
  # nobody understands (a typo such as `:allways`) must not read as "safe": fail closed.
  defp dangerous?(%{tool: %Tool{} = tool}) do
    Logger.warning(
      "[PhoenixKit.API] #{tool.name} declares danger #{inspect(tool.danger)}, which is not understood, so every call counts as dangerous"
    )

    true
  end

  # The tool's own check. It is called with the context of a dry run and may read, never
  # write. A check that crashes, or answers anything but a boolean, counts as "dangerous":
  # the safe answer to not knowing.
  defp function_danger?(%Tool{danger: {module, function}} = tool, state) do
    case apply(module, function, [state.input, Executor.context(state, dry_run?: true)]) do
      answer when is_boolean(answer) ->
        answer

      other ->
        Logger.warning(
          "[PhoenixKit.API] the danger check of #{tool.name} answered #{LogSafe.shape(other)} instead of true or false, so the call counts as dangerous"
        )

        true
    end
  rescue
    error ->
      Logger.warning(
        "[PhoenixKit.API] the danger check of #{tool.name} failed, so the call counts as dangerous: #{LogSafe.exception_label(error)}"
      )

      true
  catch
    kind, reason ->
      Logger.warning(
        "[PhoenixKit.API] the danger check of #{tool.name} failed, so the call counts as dangerous: #{kind}: #{LogSafe.shape(reason)}"
      )

      true
  end

  # Admin write tools only: a public call of fifty lines is not a batch to confirm.
  defp batch_danger?(%{audience: :admin, rows: rows}), do: rows > FlowConfig.confirm_batch_over()
  defp batch_danger?(_state), do: false

  # --- the confirmation flow ---------------------------------------------------------------

  defp confirm_flow(state) do
    cond do
      state.audience == :public and is_nil(state.actor.client_token_hash) ->
        {:error, :validation_failed, "A client token is required for this operation.",
         %{
           errors: [
             %{
               path: state.tool.client_token || "",
               message: "is required",
               limit: nil,
               allowed: nil
             }
           ]
         }, state}

      is_binary(state.control["confirm_token"]) ->
        redeem(state, state.control["confirm_token"])

      approval_key?(state) ->
        request_approval(state)

      true ->
        issue(state)
    end
  end

  defp approval_key?(%{actor: %{kind: :key, requires_approval: true}}), do: true
  defp approval_key?(_state), do: false

  # Confirmation code, second call: cheap checks, a fresh dry run for the fingerprint, then the atomic
  # claim. Only a successful claim spends the code.
  defp redeem(state, token) do
    if approval_key?(state) do
      invalid_token(state, :approval_key, nil)
    else
      with {:ok, row} <-
             Confirm.lookup_token(token, state.actor, state.tool.name, state.input_hash),
           {:ok, previewed} <- Executor.preview(state),
           :ok <- claim_code(row, previewed) do
        {:ok, %{state | confirmation: row}}
      else
        {:error, reason} when is_atom(reason) -> invalid_token(state, reason, nil)
        {:invalid, reason, previewed} -> invalid_token(state, reason, previewed)
        {:error, _code, _detail, _context, _state} = error -> error
      end
    end
  end

  defp claim_code(row, previewed) do
    case Confirm.claim_token(row, previewed.preview.fingerprint) do
      :ok -> :ok
      {:error, reason} -> {:invalid, reason, previewed}
    end
  end

  # 409 with a fresh preview, so the caller sees what the call would do now.
  defp invalid_token(state, reason, previewed) do
    preview =
      case previewed || fresh_preview(state) do
        %{preview: %{data: data}} -> data
        _no_preview -> nil
      end

    {:error, :confirm_token_invalid,
     "The confirmation code is not valid (#{label(reason)}). Repeat the call without it to get a new preview and a new code.",
     %{reason: label(reason), preview: preview}, state}
  end

  defp fresh_preview(state) do
    case Executor.preview(state) do
      {:ok, previewed} -> previewed
      _error -> nil
    end
  end

  defp label(reason) when reason in [:malformed, :unknown, :wrong_binding], do: "invalid"
  defp label(:wrong_input), do: "other_arguments"
  defp label(:other_origin), do: "other_origin"
  defp label(:used), do: "used"
  defp label(:rejected), do: "rejected"
  defp label(:expired), do: "expired"
  defp label(:changed), do: "changed"
  defp label(:approval_key), do: "approval_required"

  # Confirmation code, first call.
  defp issue(state) do
    with {:ok, previewed} <- Executor.preview(state),
         {:ok, issued} <-
           Confirm.issue_token(
             state.actor,
             state.tool.name,
             state.input_hash,
             previewed.preview.data,
             previewed.preview.fingerprint
           ) do
      body = %{
        "executed" => false,
        "status" => "confirmation_required",
        "preview" => previewed.preview.data,
        "confirm_token" => issued.token,
        "expires_at" => DateTime.to_iso8601(issued.row.expires_at),
        "expires_in_seconds" => issued.expires_in_seconds
      }

      {:done, answer(previewed, body, "confirmation_required")}
    else
      {:error, :no_secret} ->
        {:error, :internal_error,
         "Confirmation codes are unavailable: the host has no secret_key_base.", %{}, state}

      {:error, reason} ->
        Logger.error(
          "[PhoenixKit.API] could not issue a confirmation code for #{state.tool.name}: #{LogSafe.shape(reason)}"
        )

        {:error, :internal_error, "The confirmation code could not be issued.", %{}, state}

      {:error, _code, _detail, _context, _state} = error ->
        error
    end
  end

  # --- a person's live session ----------------------------------------------------------

  defp session?(%{actor: %{kind: :user}}), do: true
  defp session?(_state), do: false

  # Every write of a session waits for the person, so the values cannot change between the
  # preview they see and the run they confirm unnoticed. A session holds no code: one sent
  # anyway is checked as a code and refused (`Confirm.lookup_token/5` never accepts a
  # session's row).
  defp session_flow(state) do
    case state.control["confirm_token"] do
      token when is_binary(token) -> redeem(state, token)
      _none -> hold_for_session(state)
    end
  end

  # The preview and a new row, answered with the row's uuid, never a code.
  defp hold_for_session(state) do
    with {:ok, previewed} <- Executor.preview(state),
         {:ok, row} <- issue_for_session(state, previewed) do
      {:done, session_prompt(previewed, row, %{})}
    end
  end

  defp issue_for_session(state, previewed) do
    state.actor
    |> Confirm.issue_for_user(
      state.tool.name,
      state.input_hash,
      previewed.preview.data,
      previewed.preview.fingerprint,
      DateTime.utc_now(),
      context: Confirm.origin_context(state.session_ref)
    )
    |> session_row(state)
  end

  defp session_row({:ok, row}, _state), do: {:ok, row}

  defp session_row({:error, reason}, state) do
    Logger.error(
      "[PhoenixKit.API] could not hold #{state.tool.name} for confirmation: #{LogSafe.shape(reason)}"
    )

    {:error, :internal_error, "The operation could not be held for confirmation.", %{}, state}
  end

  defp session_prompt(previewed, row, extra) do
    body =
      Map.merge(
        %{
          "executed" => false,
          "status" => "confirmation_required",
          "confirmation_id" => row.uuid,
          "preview" => previewed.preview.data,
          "expires_at" => DateTime.to_iso8601(row.expires_at),
          "expires_in_seconds" => max(DateTime.diff(row.expires_at, DateTime.utc_now()), 0)
        },
        extra
      )

    %{answer(previewed, body, "confirmation_required") | confirmation: row}
  end

  @doc """
  The person confirms the write their session's call was held for: the step that takes
  the place of `gate/1` in `PhoenixKit.API.Executor.redeem_as/6`. The state has passed the
  whole request path again, so this checks only the row: it must be the person's
  (`Confirm.lookup_for_user/2`), for the same tool and arguments, still waiting
  (`Confirm.redeemable/4`); then the handler runs as a dry run for a fresh fingerprint and
  `Confirm.claim_token/3` spends the row, atomically. `{:ok, state}` goes on to run the
  handler.

  When the values changed since the preview, nothing runs: the row is replaced by a new
  one with the fresh preview (`Confirm.reissue_for_user/7`) and the answer is the prompt of
  the new row with `"reason" => "changed"`. Any other refusal is `409
  confirm_token_invalid` with `context.reason` `invalid` (unknown or somebody else's),
  `other_arguments`, `used`, `rejected` or `expired`, without a preview. A linked Telegram
  chat redeems only a row held for that chat (`Confirm.from_origin?/2`): any other row of the
  person is refused with `context.reason` `other_origin`, before its status is looked at, and
  is left as it was. The row that replaces one whose values changed keeps the old row's
  `context`.
  """
  def redeem_for_session(state, confirmation_uuid) do
    with {:ok, row} <- Confirm.lookup_for_user(confirmation_uuid, state.actor.user_uuid),
         :ok <- own_origin(state, row),
         :ok <- Confirm.redeemable(row, state.tool.name, state.input_hash),
         {:ok, previewed} <- Executor.preview(state) do
      case Confirm.claim_token(row, previewed.preview.fingerprint) do
        :ok -> {:ok, %{state | confirmation: row}}
        {:error, :changed} -> reissue_for_session(state, row, previewed)
        {:error, reason} -> session_invalid(state, reason)
      end
    else
      {:error, reason} when is_atom(reason) -> session_invalid(state, reason)
      {:error, _code, _detail, _context, _state} = error -> error
    end
  end

  # A linked chat redeems only a row held for that chat; a site session redeems any row of
  # the person. Checked before the status, so a refusal says nothing about the row.
  defp own_origin(%{session_ref: {:telegram_link, _, _, _} = chat}, row),
    do: if(Confirm.from_origin?(row, chat), do: :ok, else: {:error, :other_origin})

  defp own_origin(_state, _row), do: :ok

  defp reissue_for_session(state, row, previewed) do
    case Confirm.reissue_for_user(
           row,
           state.actor,
           state.tool.name,
           state.input_hash,
           previewed.preview.data,
           previewed.preview.fingerprint
         ) do
      {:ok, new_row} ->
        prompt = session_prompt(previewed, new_row, %{"reason" => "changed"})
        {:done, %{prompt | replaces_confirmation_uuid: row.uuid}}

      {:error, reason} when is_atom(reason) and reason != :no_binding ->
        session_invalid(state, reason)

      {:error, reason} ->
        session_row({:error, reason}, state)
    end
  end

  defp session_invalid(state, reason) do
    {:error, :confirm_token_invalid,
     "The confirmation is not valid (#{label(reason)}). Ask for the operation again to get a new preview.",
     %{reason: label(reason)}, state}
  end

  # Approval queue.
  defp request_approval(state) do
    with {:ok, previewed} <- Executor.preview(state),
         {:ok, row, queued} <-
           Approvals.request(%{
             actor: state.actor,
             tool: state.tool.name,
             input: state.input,
             input_hash: state.input_hash,
             preview: previewed.preview.data,
             fingerprint: previewed.preview.fingerprint,
             context: snapshot(state)
           }) do
      body = %{
        "executed" => false,
        "status" => "pending_approval",
        "approval_id" => row.uuid,
        "preview" => row.preview,
        "expires_at" => DateTime.to_iso8601(row.expires_at),
        "expires_in_seconds" => max(DateTime.diff(row.expires_at, DateTime.utc_now()), 0)
      }

      {:done, %{answer(previewed, body, "pending_approval") | held_again?: queued == :existing}}
    else
      {:error, :pending_cap} ->
        {:error, :rate_limited,
         "This key already has the maximum number of operations waiting for approval.",
         %{retry_after: 300, pending_max: FlowConfig.approval_pending_max()}, state}

      {:error, :input_too_large} ->
        {:error, :payload_too_large,
         "The input is too large to wait for approval (the limit is 1 MB).", %{}, state}

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.error(
          "[PhoenixKit.API] could not queue an approval for #{state.tool.name}: " <>
            "#{LogSafe.shape(changeset)} with invalid fields #{inspect(Keyword.keys(changeset.errors))}"
        )

        {:error, :internal_error, "The operation could not be queued for approval.", %{}, state}

      {:error, _code, _detail, _context, _state} = error ->
        error
    end
  end

  # What the approval will run with later, when there is no request any more.
  defp snapshot(state) do
    ctx = Executor.context(state)

    %{
      "language" => ctx.language,
      "currency" => ctx.currency,
      "hosts" => ctx.hosts,
      "base_url" => ctx.base_url,
      "request_id" => ctx.request_id
    }
  end

  # An answer that is not the result of the call (a preview, a prompt): never stored. `body`
  # must hold only JSON-safe data (the preview is made so by the executor), so it is its own
  # decoded form, which a transport that wants the map (MCP's `structuredContent`) reads
  # from `:result`.
  defp answer(state, body, outcome) do
    %{state | body: JSON.encode!(body), outcome: outcome, store?: false, result: body}
  end
end
