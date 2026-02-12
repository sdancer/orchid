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

      assert length(tools) == 11
      assert Enum.any?(tools, &(&1.name == "shell"))
      assert Enum.any?(tools, &(&1.name == "sandbox_reset"))
      assert Enum.any?(tools, &(&1.name == "eval"))
    end

    test "execute shell command" do
      {:ok, result} = Orchid.Tool.execute("shell", %{"command" => "echo hello"}, %{})
      assert String.trim(result) == "hello"
    end

    test "execute eval" do
      {:ok, result} = Orchid.Tool.execute("eval", %{"code" => "2 * 3"}, %{})
      assert result == "6"
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
end
