defmodule PhoenixKit.Migrations.Repair.ReportTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.Repair.Report

  @versions %{comment: 135, floor: 121, current: 151}

  defp finding(kind, severity, message \\ "x") do
    %{kind: kind, severity: severity, object_id: "table:t", since: 1, message: message}
  end

  describe "new/3, add_finding/2, findings/1" do
    test "starts empty, appends in order" do
      report = Report.new("public", false, @versions)
      assert Report.findings(report) == []

      report =
        report
        |> Report.add_finding(finding(:missing, :repairable, "first"))
        |> Report.add_finding(finding(:pending, :info, "second"))

      assert Enum.map(Report.findings(report), & &1.message) == ["first", "second"]
    end
  end

  describe "exit_code/1 — highest severity wins" do
    test "no findings → 0" do
      report = Report.new("public", true, @versions)
      assert Report.exit_code(report) == 0
    end

    test "only info-severity findings → 0" do
      report =
        Report.new("public", true, @versions) |> Report.add_finding(finding(:pending, :info))

      assert Report.exit_code(report) == 0
    end

    test "a repairable finding, no errors → 1" do
      report =
        Report.new("public", true, @versions)
        |> Report.add_finding(finding(:missing, :repairable))

      assert Report.exit_code(report) == 1
    end

    test "an error-severity finding → 2, even alongside repairable and info findings" do
      report =
        Report.new("public", false, @versions)
        |> Report.add_finding(finding(:pending, :info))
        |> Report.add_finding(finding(:repaired, :repairable))
        |> Report.add_finding(finding(:wrong_shape, :error))

      assert Report.exit_code(report) == 2
    end

    test "error dominates repairable regardless of finding order" do
      report =
        Report.new("public", false, @versions)
        |> Report.add_finding(finding(:create_failed, :error))
        |> Report.add_finding(finding(:repaired, :repairable))

      assert Report.exit_code(report) == 2
    end
  end

  describe "summary/1" do
    test "counts total, by_severity, and by_kind" do
      report =
        Report.new("public", true, @versions)
        |> Report.add_finding(finding(:missing, :repairable))
        |> Report.add_finding(finding(:missing, :repairable))
        |> Report.add_finding(finding(:pending, :info))

      summary = Report.summary(report)
      assert summary.total == 3
      assert summary.by_severity == %{repairable: 2, info: 1}
      assert summary.by_kind == %{missing: 2, pending: 1}
    end

    test "empty report" do
      summary = Report.new("public", true, @versions) |> Report.summary()
      assert summary == %{total: 0, by_severity: %{}, by_kind: %{}}
    end
  end

  describe "put_comment_action/2" do
    test "defaults to :none" do
      report = Report.new("public", true, @versions)
      assert report.comment_action == :none
    end

    test "records a tagged action" do
      report = Report.new("public", false, @versions) |> Report.put_comment_action({:healed, 140})
      assert report.comment_action == {:healed, 140}
    end
  end

  describe "to_json_map/1" do
    test "flattens :absent, nil, and integer comments to JSON-safe scalars" do
      for {comment, expected} <- [{:absent, "absent"}, {nil, nil}, {135, 135}] do
        report = Report.new("public", false, %{@versions | comment: comment})
        assert Report.to_json_map(report).versions.comment == expected
      end
    end

    test "flattens comment_action, including :none, to a plain map" do
      report = Report.new("public", true, @versions)
      assert Report.to_json_map(report).comment_action == %{action: "none"}

      report = Report.put_comment_action(report, {:would_heal, 140})
      assert Report.to_json_map(report).comment_action == %{action: "would_heal", version: 140}
    end

    test "includes prefix, dry_run, summary, exit_code, and ordered findings" do
      report =
        Report.new("auth", true, @versions)
        |> Report.add_finding(finding(:missing, :repairable))

      json = Report.to_json_map(report)
      assert json.prefix == "auth"
      assert json.dry_run == true
      assert json.exit_code == 1
      assert json.summary.total == 1
      assert length(json.findings) == 1
    end

    test "every value is Jason-encodable" do
      report =
        Report.new("public", false, @versions)
        |> Report.add_finding(finding(:wrong_shape, :error))
        |> Report.put_comment_action({:healed, 140})

      assert {:ok, _encoded} = Jason.encode(Report.to_json_map(report))
    end
  end
end
