defmodule MCPO.ToolSpec do
  @moduledoc false

  # Builds the tool list for the MCP server adapters from `tools:` entries.
  # Values come from the entry options, then `use MCPO.Tool`, then the Oban Pro
  # `args_schema`, then the defaults.

  @type t :: %{name: String.t(), worker: module(), description: String.t(), input_schema: map()}

  @spec build([module() | {module(), keyword()}]) :: [t()]
  def build(tools) do
    specs = Enum.map(tools, &spec/1)
    names = Enum.map(specs, fn %{name: name} -> name end)

    case names -- Enum.uniq(names) do
      [] -> specs
      duplicates -> raise ArgumentError, "duplicate MCPO tool names: #{inspect(duplicates)}"
    end
  end

  defp spec(worker) when is_atom(worker), do: spec({worker, []})

  defp spec({worker, opts}) when is_atom(worker) and is_list(opts) do
    Code.ensure_compiled!(worker)

    if not function_exported?(worker, :perform, 1) do
      raise ArgumentError, "#{inspect(worker)} is not an Oban worker"
    end

    opts = Keyword.merge(MCPO.Tool.options(worker), opts)

    %{
      name: Keyword.get_lazy(opts, :name, fn -> default_name(worker) end),
      worker: worker,
      description:
        Keyword.get(opts, :description, "Runs #{inspect(worker)} as a background job."),
      input_schema:
        Keyword.get_lazy(opts, :input_schema, fn ->
          MCPO.ArgsSchema.from_worker(worker) || %{"type" => "object"}
        end)
    }
  end

  defp default_name(worker) do
    worker
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end
end
