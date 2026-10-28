defmodule SiteMaps.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [{Task.Supervisor, name: SiteMaps.TaskSupervisor}]
    Supervisor.start_link(children, strategy: :one_for_one, name: SiteMaps.Supervisor)
  end
end
