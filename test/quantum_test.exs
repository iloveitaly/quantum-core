defmodule QuantumTest do
  use ExUnit.Case, async: false

  alias Quantum.Job

  import Crontab.CronExpression

  defmodule Runner do
    use Quantum, otp_app: :quantum_test
  end

  defmodule ZeroTimeoutRunner do
    use Quantum, otp_app: :quantum_test
  end

  defp start_runner(name) do
    {:ok, _pid} = name.start_link()
    on_exit fn ->
      case Process.whereis(Quantum.Supervisor) do
        nil ->
          :ok
        pid ->
          name.stop(pid)
      end
    end
  end

  setup do
    Application.put_env(:quantum_test, QuantumTest.Runner, jobs: [])
    Application.put_env(:quantum_test, QuantumTest.ZeroTimeoutRunner, timeout: 0, jobs: [])

    start_runner(QuantumTest.Runner)
    start_runner(QuantumTest.ZeroTimeoutRunner)
  end

  describe "new_job/0" do
    test "returns Quantum.Job struct" do
      %Quantum.Job{schedule: schedule, overlap: overlap, timezone: timezone} = QuantumTest.Runner.new_job()

      assert schedule == nil
      assert overlap == true
      assert timezone == :utc
    end

    test "has defaults set" do
      default_schedule = ~e[*/7]
      default_overlap = false
      default_timezone = "Europe/Zurich"
      Application.put_env(:quantum_test, QuantumTest.Runner, [
        jobs: [],
        default_schedule: default_schedule,
        default_overlap: default_overlap,
        default_timezone: default_timezone
      ])

      %Quantum.Job{schedule: schedule, overlap: overlap, timezone: timezone} = QuantumTest.Runner.new_job()

      assert schedule == default_schedule
      assert overlap == default_overlap
      assert timezone == default_timezone
    end
  end

  test "adding a job at run time" do
    spec = ~e[1 * * * *]
    fun = fn -> :ok end
    :ok = QuantumTest.Runner.add_job(spec, fun)
    job = QuantumTest.Runner.new_job()
    |> Job.set_schedule(spec)
    |> Job.set_task(fun)
    assert Enum.member? QuantumTest.Runner.jobs, {nil, job}
  end

  describe "add_job/2" do
    test "adding a job at run time" do
      spec = ~e[1 * * * *]
      fun = fn -> :ok end

      :ok = QuantumTest.Runner.add_job(spec, fun)
      job = QuantumTest.Runner.new_job()
      |> Job.set_schedule(spec)
      |> Job.set_task(fun)
      assert Enum.member? QuantumTest.Runner.jobs, {nil, job}
    end

    test "adding a named job struct at run time" do
      spec = ~e[1 * * * *]
      fun = fn -> :ok end
      job = QuantumTest.Runner.new_job()
      |> Job.set_name(:test_job)
      |> Job.set_schedule(spec)
      |> Job.set_task(fun)
      :ok = QuantumTest.Runner.add_job(job)
      assert Enum.member? QuantumTest.Runner.jobs, {:test_job, %{job | nodes: [node()]}}
    end

    test "adding a named {m, f, a} jpb at run time" do
      spec = ~e[1 * * * *]
      task = {IO, :puts, ["Tick"]}
      job = QuantumTest.Runner.new_job()
      |> Job.set_name(:ticker)
      |> Job.set_schedule(spec)
      |> Job.set_task(task)
      :ok = QuantumTest.Runner.add_job(job)
      assert Enum.member? QuantumTest.Runner.jobs, {:ticker, %{job | nodes: [node()]}}
    end

    test "adding a unnamed job at run time" do
      spec = ~e[1 * * * *]
      fun = fn -> :ok end
      job = QuantumTest.Runner.new_job()
      |> Job.set_schedule(spec)
      |> Job.set_task(fun)
      :ok = QuantumTest.Runner.add_job(job)
      assert Enum.member? QuantumTest.Runner.jobs, {nil, job}
    end
  end

  test "finding a named job" do
    spec = ~e[* * * * *]
    fun = fn -> :ok end
    job = QuantumTest.Runner.new_job()
    |> Job.set_name(:test_job)
    |> Job.set_schedule(spec)
    |> Job.set_task(fun)
    :ok = QuantumTest.Runner.add_job(job)
    fjob = QuantumTest.Runner.find_job(:test_job)
    assert fjob.name == :test_job
    assert fjob.schedule == spec
    assert fjob.nodes == [node()]
  end

  test "deactivating a named job" do
    spec = ~e[* * * * *]
    fun = fn -> :ok end
    job = QuantumTest.Runner.new_job()
    |> Job.set_name(:test_job)
    |> Job.set_schedule(spec)
    |> Job.set_task(fun)

    :ok = QuantumTest.Runner.add_job(job)
    :ok = QuantumTest.Runner.deactivate_job(:test_job)
    sjob = QuantumTest.Runner.find_job(:test_job)
    assert sjob == %{job | state: :inactive}
  end

  test "activating a named job" do
      spec = ~e[* * * * *]
      fun = fn -> :ok end

      job = QuantumTest.Runner.new_job()
      |> Job.set_name(:test_job)
      |> Job.set_state(:inactive)
      |> Job.set_schedule(spec)
      |> Job.set_task(fun)

      :ok = QuantumTest.Runner.add_job(job)
      :ok = QuantumTest.Runner.activate_job(:test_job)
      ajob = QuantumTest.Runner.find_job(:test_job)
      assert ajob == %{job | state: :active}
  end

  test "deleting a named job at run time" do
    spec = ~e[* * * * *]
    fun = fn -> :ok end

    job = QuantumTest.Runner.new_job()
    |> Job.set_name(:test_job)
    |> Job.set_schedule(spec)
    |> Job.set_task(fun)

    :ok = QuantumTest.Runner.add_job(job)
    djob = QuantumTest.Runner.delete_job(:test_job)
    assert djob.name == :test_job
    assert djob.schedule == spec
    assert !Enum.member? QuantumTest.Runner.jobs, {:test_job, job}
  end

  test "deleting all jobs" do
    for i <- 1..3 do
      name = String.to_atom("test_job_" <> Integer.to_string(i))
      spec = ~e[* * * * *]
      fun = fn -> :ok end
      job = QuantumTest.Runner.new_job()
      |> Job.set_name(name)
      |> Job.set_schedule(spec)
      |> Job.set_task(fun)
      :ok = QuantumTest.Runner.add_job(job)
    end
    assert Enum.count(QuantumTest.Runner.jobs) == 3
    QuantumTest.Runner.delete_all_jobs
    assert QuantumTest.Runner.jobs == []
  end

  test "prevent duplicate job names" do
    # note that "test_job", :test_job and 'test_job' are regarded as different names

    job = QuantumTest.Runner.new_job()
    |> Job.set_name(:test_job)
    |> Job.set_schedule(~e[* * * * *])
    |> Job.set_task(fn -> :ok end)

    assert QuantumTest.Runner.add_job(job) == :ok
    assert QuantumTest.Runner.add_job(job) == :error
  end

  test "handle_call for :which_children" do
    state = %{jobs: [], d: nil, h: nil, m: nil, w: nil, r: 0}
    children = [{Task.Supervisor, :quantum_tasks_sup, :supervisor, [Task.Supervisor]}]
    assert Quantum.Scheduler.handle_call(:which_children, :test, state) == {:reply, children, state}
  end

  test "execute for current node" do
    {:ok, pid1} = Agent.start_link(fn -> nil end)
    {:ok, pid2} = Agent.start_link(fn -> 0 end)

    start_date = NaiveDateTime.utc_now
    # Reset MS
    |> NaiveDateTime.to_erl
    |> NaiveDateTime.from_erl!
    |> NaiveDateTime.add(-1)

    end_date = start_date
    |> NaiveDateTime.add(1)

    fun = fn ->
      fun_pid = self()
      Agent.update(pid1, fn(_) -> fun_pid end)
      Agent.update(pid2, fn(n) -> n + 1 end)
    end

    job = QuantumTest.Runner.new_job()
    |> Job.set_schedule(~e[* * * * *]e)
    |> Job.set_task(fun)

    state1 = %{opts: QuantumTest.Runner.config(), jobs: [{nil, job}], date: start_date, reboot: false}
    state3 = Quantum.Scheduler.handle_info(:tick, state1)
    :timer.sleep(500)
    assert Agent.get(pid2, fn(n) -> n end) == 1
    job = %{job | pid: Agent.get(pid1, fn(n) -> n end)}
    state2 = %{opts: QuantumTest.Runner.config(), jobs: [{nil, job}], date: end_date, reboot: false}
    assert state3 == {:noreply, state2}
    :ok = Agent.stop(pid2)
    :ok = Agent.stop(pid1)
  end

  test "skip for current node" do
    {:ok, pid} = Agent.start_link(fn -> 0 end)

    start_date = NaiveDateTime.utc_now
    # Reset MS
    |> NaiveDateTime.to_erl
    |> NaiveDateTime.from_erl!
    |> NaiveDateTime.add(-1)

    end_date = start_date
    |> NaiveDateTime.add(1)

    fun = fn -> Agent.update(pid, fn(n) -> n + 1 end) end
    job = QuantumTest.Runner.new_job()
    |> Job.set_schedule(~e[* * * * *])
    |> Job.set_task(fun)
    |> Job.set_nodes([:remote@node])
    state1 = %{jobs: [{nil, job}], date: start_date, reboot: false}
    state2 = %{jobs: [{nil, job}], date: end_date, reboot: false}
    assert Quantum.Scheduler.handle_info(:tick, state1) == {:noreply, state2}
    :timer.sleep(500)
    assert Agent.get(pid, fn(n) -> n end) == 0
    :ok = Agent.stop(pid)
  end

  test "reboot" do
    {:ok, pid1} = Agent.start_link(fn -> nil end)
    {:ok, pid2} = Agent.start_link(fn -> 0 end)
    fun = fn ->
      fun_pid = self()
      Agent.update(pid1, fn(_) -> fun_pid end)
      Agent.update(pid2, fn(n) -> n + 1 end)
    end
    job = QuantumTest.Runner.new_job()
    |> Job.set_schedule(~e[@reboot])
    |> Job.set_task(fun)
    {:ok, state} = Quantum.Scheduler.init(%{opts: QuantumTest.Runner.config(), jobs: [{nil, job}], reboot: true})
    :timer.sleep(500)
    job = %{job | pid: Agent.get(pid1, fn(n) -> n end)}
    assert state.jobs == [{nil, job}]
    assert Agent.get(pid2, fn(n) -> n end) == 1
    :ok = Agent.stop(pid2)
    :ok = Agent.stop(pid1)
  end

  test "overlap, first start" do
    {:ok, pid1} = Agent.start_link(fn -> nil end)
    {:ok, pid2} = Agent.start_link(fn -> 0 end)

    start_date = NaiveDateTime.utc_now
    # Reset MS
    |> NaiveDateTime.to_erl
    |> NaiveDateTime.from_erl!
    |> NaiveDateTime.add(-1)

    end_date = start_date
    |> NaiveDateTime.add(1)

    fun = fn ->
      fun_pid = self()
      Agent.update(pid1, fn(_) -> fun_pid end)
      Agent.update(pid2, fn(n) -> n + 1 end)
    end
    job = QuantumTest.Runner.new_job()
    |> Job.set_schedule(~e[* * * * *]e)
    |> Job.set_overlap(false)
    |> Job.set_task(fun)

    state1 = %{opts: QuantumTest.Runner.config(), jobs: [{nil, job}], date: start_date, reboot: false}
    state3 = Quantum.Scheduler.handle_info(:tick, state1)
    :timer.sleep(500)
    assert Agent.get(pid2, fn(n) -> n end) == 1

    job = %{job | pid: Agent.get(pid1, fn(n) -> n end)}

    state2 = %{opts: QuantumTest.Runner.config(), jobs: [{nil, job}], date: end_date, reboot: false}

    assert state3 == {:noreply, state2}

    :ok = Agent.stop(pid2)
    :ok = Agent.stop(pid1)
  end

  test "overlap, second start" do
    {:ok, pid1} = Agent.start_link(fn -> nil end)
    {:ok, pid2} = Agent.start_link(fn -> 0 end)

    start_date = NaiveDateTime.utc_now
    # Reset MS
    |> NaiveDateTime.to_erl
    |> NaiveDateTime.from_erl!
    |> NaiveDateTime.add(-1)

    end_date = start_date
    |> NaiveDateTime.add(1)

    fun = fn ->
      fun_pid = self()
      Agent.update(pid1, fn(_) -> fun_pid end)
      Agent.update(pid2, fn(n) -> n + 1 end)
    end
    job = QuantumTest.Runner.new_job()
    |> Job.set_schedule(~e[* * * * *])
    |> Job.set_overlap(false)
    |> Job.set_task(fun)
    |> Map.put(:pid, pid1)
    state1 = %{jobs: [{nil, job}], date: start_date, reboot: false}
    state3 = Quantum.Scheduler.handle_info(:tick, state1)
    :timer.sleep(500)
    assert Agent.get(pid2, fn(n) -> n end) == 0
    job = %{job | pid: pid1}
    state2 = %{jobs: [{nil, job}], date: end_date, reboot: false}
    assert state3 == {:noreply, state2}
    :ok = Agent.stop(pid2)
    :ok = Agent.stop(pid1)
  end

  test "do not crash sibling jobs when a job crashes" do
    fun = fn ->
      receive do
        :ping -> :pong
      end
    end

    job_sibling = QuantumTest.Runner.new_job()
    |> Job.set_name(:job_sibling)
    |> Job.set_schedule(~e[* * * * *]e)
    |> Job.set_task(fun)

    assert QuantumTest.Runner.add_job(job_sibling) == :ok

    job_to_crash = QuantumTest.Runner.new_job()
    |> Job.set_name(:job_to_crash)
    |> Job.set_schedule(~e[* * * * *]e)
    |> Job.set_task(fun)

    assert QuantumTest.Runner.add_job(job_to_crash) == :ok

    assert Enum.count(QuantumTest.Runner.jobs) == 2

    send(QuantumTest.Runner.Scheduler, :tick)

    %Quantum.Job{pid: pid_sibling} = QuantumTest.Runner.find_job(:job_sibling)
    %Quantum.Job{pid: pid_to_crash} = QuantumTest.Runner.find_job(:job_to_crash)

    # both processes are alive
    :ok = ensure_alive(pid_sibling)
    :ok = ensure_alive(pid_to_crash)

    # Stop the job with non-normal reason
    Process.exit(pid_to_crash, :shutdown)

    ref_sibling = Process.monitor(pid_sibling)
    ref_to_crash = Process.monitor(pid_to_crash)

    # Wait until the job to crash is dead
    assert_receive {:DOWN, ^ref_to_crash, _, _, _}

    # sibling job shouldn't crash
    refute_receive {:DOWN, ^ref_sibling, _, _, _}
  end

  test "preserve state if one of the jobs crashes" do
    job1 = QuantumTest.Runner.new_job()
    |> Job.set_schedule(~e[* * * * *])
    |> Job.set_task(fn -> :ok end)
    assert QuantumTest.Runner.add_job(job1) == :ok

    fun = fn ->
      receive do
        :ping -> :pong
      end
    end

    job_to_crash = QuantumTest.Runner.new_job()
    |> Job.set_name(:job_to_crash)
    |> Job.set_schedule(~e[* * * * *]e)
    |> Job.set_task(fun)

    assert QuantumTest.Runner.add_job(job_to_crash) == :ok

    assert Enum.count(QuantumTest.Runner.jobs) == 2

    send(QuantumTest.Runner.Scheduler, :tick)

    assert Enum.count(QuantumTest.Runner.jobs) == 2

    %Quantum.Job{pid: pid_to_crash} = QuantumTest.Runner.find_job(:job_to_crash)

    # ensure process to crash is alive
    :ok = ensure_alive(pid_to_crash)

    # Stop the job with non-normal reason
    Process.exit(pid_to_crash, :shutdown)

    # Wait until the job is dead
    ref = Process.monitor(pid_to_crash)
    assert_receive {:DOWN, ^ref, _, _, _}

    # ensure there is a new process registered for Quantum
    # in case Quantum process gets restarted because of
    # the crashed job
    :ok = ensure_registered(QuantumTest.Runner.Scheduler)

    # after process crashed we should still have 2 jobs scheduled
    assert Enum.count(QuantumTest.Runner.jobs) == 2
  end

  test "timeout can be configured for genserver correctly" do
    job = QuantumTest.ZeroTimeoutRunner.new_job()
    |> Job.set_name(:tmpjob)
    |> Job.set_schedule(~e[* */5 * * *])
    |> Job.set_task(fn -> :ok end)

    assert catch_exit(QuantumTest.ZeroTimeoutRunner.add_job(job)) ==
      {:timeout, {GenServer, :call, [QuantumTest.ZeroTimeoutRunner.Scheduler, {:find_job, :tmpjob}, 0]}}
  after
    Application.delete_env(:quantum, :timeout)
  end

  # loop until given process is alive
  defp ensure_alive(pid) do
    case Process.alive?(pid) do
      false ->
        :timer.sleep(10)
        ensure_alive(pid)
      true -> :ok
    end
  end

  # loop until given process is registered
  defp ensure_registered(registered_process) do
    case Process.whereis(registered_process) do
      nil ->
        :timer.sleep(10)
        ensure_registered(registered_process)
      _ -> :ok
    end
  end
end
