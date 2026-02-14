defmodule Orchid.GoalReviewQueue do
  @moduledoc """
  Serializes worker goal completion reviews to avoid flooding reviewer LLM calls.
  """
  use GenServer
  require Logger

  @type queue_item :: %{
          agent_id: String.t(),
          project_id: String.t(),
          report: String.t()
        }

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Enqueue a completion review request for a worker response.
  """
  def enqueue(agent_id, project_id, report)
      when is_binary(agent_id) and is_binary(project_id) and is_binary(report) do
    GenServer.cast(
      __MODULE__,
      {:enqueue, %{agent_id: agent_id, project_id: project_id, report: report}}
    )
  end

  @impl true
  def init(:ok) do
    {:ok, %{queue: :queue.new(), in_flight: nil}}
  end

  @impl true
  def handle_cast({:enqueue, item}, state) do
    queue = :queue.in(item, state.queue)
    state = %{state | queue: queue}
    Logger.debug("GoalReviewQueue: enqueued review for agent #{item.agent_id}")
    Process.send(self(), :drain, [])
    {:noreply, state}
  end

  @impl true
  def handle_info(:drain, %{in_flight: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, item}, queue} ->
        task =
          Task.async(fn ->
            Orchid.Agent.run_completion_review(item.agent_id, item.project_id, item.report)
          end)

        {:noreply, %{state | queue: queue, in_flight: {item, task.ref}}}

      {:empty, _queue} ->
        {:noreply, state}
    end
  end

  def handle_info(:drain, state), do: {:noreply, state}

  def handle_info({ref, _result}, %{in_flight: {_item, ref}} = state) do
    Process.demonitor(ref, [:flush])
    Process.send(self(), :drain, [])
    {:noreply, %{state | in_flight: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{in_flight: {item, ref}} = state) do
    Logger.warning(
      "GoalReviewQueue: review failed for agent #{item.agent_id}: #{inspect(reason)}"
    )

    Process.send(self(), :drain, [])
    {:noreply, %{state | in_flight: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
