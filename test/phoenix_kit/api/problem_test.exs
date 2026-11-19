defmodule PhoenixKit.API.ProblemTest do
  @moduledoc """
  `PhoenixKit.API.Problem`: the RFC 9457 documents every API error is sent
  as. No database.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias PhoenixKit.API.Problem

  defp decode(conn), do: JSON.decode!(conn.resp_body)

  describe "status/1" do
    test "maps every documented error code" do
      # Core's own codes; a module adds its own through `api_problems/0`.
      expected = %{
        unauthorized: 401,
        forbidden: 403,
        ip_not_allowed: 403,
        approval_pending: 403,
        origin_not_allowed: 403,
        token_in_url: 400,
        invalid_json: 400,
        not_found: 404,
        module_disabled: 404,
        module_write_disabled: 403,
        method_not_allowed: 405,
        not_acceptable: 406,
        confirm_token_invalid: 409,
        revision_mismatch: 409,
        idempotency_key_reused: 409,
        idempotency_in_progress: 409,
        payload_too_large: 413,
        validation_failed: 422,
        rate_limited: 429,
        internal_error: 500
      }

      assert Problem.statuses() == expected

      for code <- Map.keys(expected) do
        assert Problem.core_code?(code)
      end

      # The shop's codes were core's until 3.0; now a module declares them.
      for code <- ~w(cart_not_found cart_locked unsupported_source insufficient_stock)a do
        refute Problem.core_code?(code)
        assert Problem.status(code) == 500
      end

      for {code, status} <- expected do
        assert Problem.status(code) == status
      end
    end

    test "an unknown code is a 500" do
      assert Problem.status(:something_new) == 500
    end
  end

  describe "body/4" do
    test "is the problem document with string keys" do
      assert Problem.body(:forbidden, "No.", %{required_scope: "a.b:c"}, "req-1") == %{
               "type" => "https://phoenixkit.dev/api/errors/forbidden",
               "title" => "Forbidden",
               "status" => 403,
               "code" => "forbidden",
               "detail" => "No.",
               "context" => %{required_scope: "a.b:c"},
               "request_id" => "req-1"
             }
    end

    test "leaves request_id out when there is none" do
      refute Map.has_key?(Problem.body(:not_found, "", %{}, nil), "request_id")
    end

    test "every code has its own title" do
      titles =
        for code <- Map.keys(Problem.statuses()), do: Problem.body(code, "", %{}, nil)["title"]

      assert length(Enum.uniq(titles)) == length(titles)
      refute "Error" in titles
    end
  end

  describe "send/4" do
    test "sends the status, the problem+json body and halts" do
      conn =
        :post
        |> conn("/x")
        |> Problem.send(:validation_failed, "Bad.", %{errors: [%{path: "/a"}]})

      assert conn.halted
      assert conn.state == :sent
      assert conn.status == 422
      assert ["application/problem+json; charset=utf-8"] = get_resp_header(conn, "content-type")
      assert ["no-store"] = get_resp_header(conn, "cache-control")

      assert %{
               "code" => "validation_failed",
               "status" => 422,
               "detail" => "Bad.",
               "context" => %{"errors" => [%{"path" => "/a"}]}
             } = decode(conn)
    end

    test "the context defaults to an empty map" do
      conn = :get |> conn("/x") |> Problem.send(:not_found, "Gone.")
      assert decode(conn)["context"] == %{}
    end

    test "takes the request id from the Auth plug's assign" do
      conn =
        :get
        |> conn("/x")
        |> assign(:phoenix_kit_api_request_id, "from-assign")
        |> Problem.send(:not_found, "")

      assert decode(conn)["request_id"] == "from-assign"
    end

    test "falls back to the x-request-id response header Plug.RequestId sets" do
      conn =
        :get
        |> conn("/x")
        |> put_resp_header("x-request-id", "from-header")
        |> Problem.send(:not_found, "")

      assert decode(conn)["request_id"] == "from-header"
    end

    test "replaces an unsafe x-request-id header by a fresh id, in the header and the body" do
      conn =
        :get
        |> conn("/x")
        |> put_resp_header("x-request-id", ~s(client "id" <script> with spaces))
        |> Problem.send(:not_found, "")

      [header] = get_resp_header(conn, "x-request-id")
      assert header =~ ~r/\A[A-Za-z0-9_-]{20}\z/
      assert decode(conn)["request_id"] == header
    end

    test "an unauthorized answer challenges for a bearer token" do
      conn = :get |> conn("/x") |> Problem.send(:unauthorized, "Who?")
      assert [~s(Bearer error="invalid_token")] = get_resp_header(conn, "www-authenticate")
    end

    test "forbidden challenges with insufficient_scope only when a scope is named" do
      with_scope =
        :get |> conn("/x") |> Problem.send(:forbidden, "No.", %{required_scope: "a.b:c"})

      assert [~s(Bearer error="insufficient_scope")] =
               get_resp_header(with_scope, "www-authenticate")

      without = :get |> conn("/x") |> Problem.send(:forbidden, "No.", %{})
      assert [] = get_resp_header(without, "www-authenticate")
    end

    test "a retry_after in the context becomes a Retry-After header" do
      conn = :get |> conn("/x") |> Problem.send(:rate_limited, "Slow down.", %{retry_after: 12})

      assert ["12"] = get_resp_header(conn, "retry-after")
      assert decode(conn)["context"] == %{"retry_after" => 12}
    end

    test "a context JSON cannot carry does not turn the error into a crash" do
      conn = :get |> conn("/x") |> Problem.send(:validation_failed, "Bad.", %{oops: {:a, :tuple}})

      assert conn.status == 422
      assert %{"code" => "validation_failed", "context" => %{}} = decode(conn)
    end

    test "an unknown code is sent as a 500 and logged" do
      log =
        capture_log(fn ->
          conn = :get |> conn("/x") |> Problem.send(:made_up, "?")
          send(self(), {:conn, conn})
        end)

      assert_received {:conn, conn}
      assert conn.status == 500
      assert decode(conn)["code"] == "made_up"
      assert log =~ "unknown error code"
      refute log =~ "made_up"
    end
  end
end
