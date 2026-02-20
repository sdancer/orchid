defmodule Orchid.NodeServerTest do
  use ExUnit.Case

  alias Orchid.Agent.NodeServer
  alias Orchid.Agent.NodeWorker

  defmodule ApprovingVerifier do
    def critique(_objective, _plan, _llm_config), do: {:approved, "ok"}
  end

  defmodule NoopReviser do
    def fix(plan, _critique, _objective, _llm_config), do: plan
  end

  defmodule SuccessPlanner do
    def decompose(objective, _completed, _llm_config) do
      [
        %{
          id: "tool_1",
          type: :tool,
          objective: "echo objective",
          tool: "task_report",
          args: %{"completed" => objective}
        }
      ]
    end
  end

  defmodule ReplanningPlanner do
    def decompose(objective, _completed, _llm_config) do
      if String.contains?(objective, "failed because") do
        [
          %{
            id: "recovered",
            type: :tool,
            objective: "recover",
            tool: "task_report",
            args: %{"completed" => "recovered"}
          }
        ]
      else
        [
          %{
            id: "fails_once",
            type: :tool,
            objective: "fail first",
            tool: "task_report",
            args: %{"completed" => "initial"}
          }
        ]
      end
    end
  end

  defmodule DelegatePlanner do
    def decompose("child objective", _completed, _llm_config) do
      [
        %{
          id: "child_tool",
          type: :tool,
          objective: "child leaf",
          tool: "task_report",
          args: %{"completed" => "child done"}
        }
      ]
    end

    def decompose(_objective, _completed, _llm_config) do
      [%{id: "delegate_1", type: :delegate, objective: "child objective"}]
    end
  end

  defmodule MostlySuccessfulTools do
    def execute(%{id: "fails_once"}, _ctx),
      do: {:error, "Tool execution failed", %{reason: "boom"}}

    def execute(task, _ctx), do: {:ok, %{task: task.id}}
  end

  defmodule SlowTools do
    def execute(task, _ctx) do
      Process.sleep(250)
      {:ok, %{task: task.id}}
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:orchid)
    :ok
  end

  test "completes a simple tool plan and reports to parent" do
    {:ok, pid} =
      NodeServer.start_link(
        parent_pid: self(),
        objective: "finish objective",
        planner_module: SuccessPlanner,
        verifier_module: ApprovingVerifier,
        reviser_module: NoopReviser,
        tools_module: MostlySuccessfulTools
      )

    ref = Process.monitor(pid)
    assert_receive {:child_success, _node_id, [%{task_id: "tool_1"}]}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "replans when a task explicitly fails" do
    {:ok, pid} =
      NodeServer.start_link(
        parent_pid: self(),
        objective: "initial objective",
        planner_module: ReplanningPlanner,
        verifier_module: ApprovingVerifier,
        reviser_module: NoopReviser,
        tools_module: MostlySuccessfulTools
      )

    ref = Process.monitor(pid)
    assert_receive {:child_success, _node_id, [%{task_id: "recovered"}]}, 1_500
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "delegates to child node and continues after child success" do
    {:ok, pid} =
      NodeServer.start_link(
        parent_pid: self(),
        objective: "root objective",
        planner_module: DelegatePlanner,
        verifier_module: ApprovingVerifier,
        reviser_module: NoopReviser,
        tools_module: MostlySuccessfulTools
      )

    ref = Process.monitor(pid)
    assert_receive {:child_success, _node_id, [%{result: [%{task_id: "child_tool"}]}]}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "node workers are discoverable while running" do
    {:ok, pid} =
      DynamicSupervisor.start_child(
        Orchid.Agent.NodeSupervisor,
        {NodeServer,
         [
           objective: "long objective",
           planner_module: SuccessPlanner,
           verifier_module: ApprovingVerifier,
           reviser_module: NoopReviser,
           tools_module: SlowTools
         ]}
      )

    workers = NodeWorker.list()
    assert Enum.any?(workers, fn w -> w.pid == pid end)
  end
end
