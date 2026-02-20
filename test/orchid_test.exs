defmodule OrchidTest do
  use ExUnit.Case

  setup do
    # Start the application for each test
    {:ok, _} = Application.ensure_all_started(:orchid)
    :ok
  end

  describe "Object" do
    test "create and read object" do
      {:ok, obj} = Orchid.Object.create(:file, "test.ex", "defmodule Test do\nend")

      assert obj.type == :file
      assert obj.name == "test.ex"
      assert obj.language == "elixir"
      assert obj.content == "defmodule Test do\nend"

      {:ok, fetched} = Orchid.Object.get(obj.id)
      assert fetched.id == obj.id
    end

    test "update object preserves history" do
      {:ok, obj} = Orchid.Object.create(:file, "test.ex", "v1")
      {:ok, updated} = Orchid.Object.update(obj.id, "v2")

      assert updated.content == "v2"
      assert length(updated.versions) == 1
      assert hd(updated.versions).content == "v1"
    end

    test "eval function object" do
      {:ok, obj} = Orchid.Object.create(:function, "add", "1 + 1")
      {:ok, result} = Orchid.Object.eval(obj.id)

      assert result == 2
    end

    test "undo restores previous version" do
      {:ok, obj} = Orchid.Object.create(:file, "test.ex", "original")
      {:ok, _} = Orchid.Object.update(obj.id, "modified")
      {:ok, restored} = Orchid.Object.undo(obj.id)

      assert restored.content == "original"
    end
  end

  describe "Tools" do
    test "list_tools returns all tools" do
      tools = Orchid.Tool.list_tools()

      assert length(tools) >= 15
      assert Enum.any?(tools, &(&1.name == "shell"))
      assert Enum.any?(tools, &(&1.name == "sandbox_reset"))
      assert Enum.any?(tools, &(&1.name == "eval"))
      refute Enum.any?(tools, &(&1.name == "project_list"))
      refute Enum.any?(tools, &(&1.name == "project_create"))

      scoped = Orchid.Tool.list_tools(["project_list", "project_create"])
      assert Enum.any?(scoped, &(&1.name == "project_list"))
      assert Enum.any?(scoped, &(&1.name == "project_create"))
    end

    test "execute shell command" do
      {:ok, result} = Orchid.Tool.execute("shell", %{"command" => "echo hello"}, %{})
      assert String.trim(result) == "hello"
    end

    test "execute eval" do
      {:ok, result} = Orchid.Tool.execute("eval", %{"code" => "2 * 3"}, %{})
      assert result == "6"
    end

    test "object_write rejects invalid candidate plan JSON" do
      {:ok, obj} = Orchid.Object.create(:artifact, "candidate_plan_alpha", "{\"goal\":\"x\"}")

      assert {:error, msg} =
               Orchid.Tools.ObjectWrite.execute(
                 %{"id" => obj.id, "content" => "{\"goal\":\"only goal\"}"},
                 %{}
               )

      assert String.contains?(msg, "candidate_plan_* field")
    end

    test "object_write accepts valid candidate plan JSON" do
      {:ok, obj} = Orchid.Object.create(:artifact, "candidate_plan_beta", "{\"goal\":\"x\"}")

      content =
        Jason.encode!(%{
          "goal" => "Implement migration",
          "strategy" => "Ecto migration",
          "steps" => ["Inspect current schema", "Write migration", "Run migration"],
          "checks" => ["mix ecto.migrate exits 0"],
          "risks" => ["Missing DB_URL"]
        })

      assert {:ok, _} =
               Orchid.Tools.ObjectWrite.execute(%{"id" => obj.id, "content" => content}, %{})
    end
  end

  describe "Agent" do
    test "create agent" do
      {:ok, agent_id} = Orchid.Agent.create()
      assert is_binary(agent_id)

      agents = Orchid.Agent.list()
      assert agent_id in agents
    end

    test "get agent state" do
      {:ok, agent_id} = Orchid.Agent.create()
      {:ok, state} = Orchid.Agent.get_state(agent_id)

      assert state.id == agent_id
      assert state.status == :idle
      assert state.messages == []
    end

    test "attach objects to agent" do
      {:ok, obj} = Orchid.Object.create(:file, "test.ex", "code")
      {:ok, agent_id} = Orchid.Agent.create()

      :ok = Orchid.Agent.attach(agent_id, obj.id)

      {:ok, state} = Orchid.Agent.get_state(agent_id)
      assert obj.id in state.objects
    end

    test "remember and recall" do
      {:ok, agent_id} = Orchid.Agent.create()

      :ok = Orchid.Agent.remember(agent_id, "key", "value")
      assert Orchid.Agent.recall(agent_id, "key") == "value"
    end

    test "stop agent removes it from list" do
      {:ok, agent_id} = Orchid.Agent.create()
      :ok = Orchid.Agent.stop(agent_id)

      agents = Orchid.Agent.list()
      refute agent_id in agents
    end
  end

  describe "Goals" do
    test "list_ready_root_goals returns only root goals with completed dependencies" do
      {:ok, project} = Orchid.Projects.create("root-goal-test")

      {:ok, dep} = Orchid.Goals.create("dep", "", project.id)

      {:ok, root_waiting} =
        Orchid.Goals.create("root waiting", "", project.id, depends_on: [dep.id])

      {:ok, ready_root} = Orchid.Goals.create("ready root", "", project.id)
      {:ok, _child} = Orchid.Goals.create("child", "", project.id, parent_goal_id: ready_root.id)

      ready_before = Orchid.Goals.list_ready_root_goals(project.id)
      assert Enum.any?(ready_before, &(&1.id == ready_root.id))
      refute Enum.any?(ready_before, &(&1.id == root_waiting.id))

      {:ok, _} = Orchid.Goals.set_status(dep.id, :completed)
      ready_after = Orchid.Goals.list_ready_root_goals(project.id)
      assert Enum.any?(ready_after, &(&1.id == root_waiting.id))
    end
  end
end
