defmodule MCPJobs.Tool do
  @moduledoc """
  Describes an Oban worker as an MCP tool.

      defmodule MyApp.Workers.GenerateReport do
        @moduledoc \"\"\"
        Generates a report in the background.
        \"\"\"

        use Oban.Worker, queue: :reports
        use MCPJobs.Tool, input_schema: %{"type" => "object", "required" => ["report_id"]}
      end

  The `@moduledoc` text becomes the tool description. The text is read when the
  worker compiles, so it works also when a release strips the docs.

  ## Options

    * `:name`: the tool name.
    * `:description`: the tool description, in place of `@moduledoc`.
    * `:input_schema`: the JSON Schema of the tool arguments.

  The options in the `tools:` list of `MCPJobs.ExMCP` override these values.
  """

  @doc false
  defmacro __using__(opts) do
    quote do
      @mcp_jobs_tool_opts unquote(opts)
      @before_compile MCPJobs.Tool
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    description =
      case Module.get_attribute(env.module, :moduledoc) do
        {_line, doc} when is_binary(doc) -> String.trim(doc)
        _false_or_nil -> nil
      end

    quote do
      @doc false
      def __mcp_jobs_tool__ do
        Keyword.put_new(@mcp_jobs_tool_opts, :description, unquote(description))
      end
    end
  end

  @doc false
  @spec options(module()) :: keyword()
  def options(worker) do
    if Code.ensure_loaded?(worker) and function_exported?(worker, :__mcp_jobs_tool__, 0) do
      Enum.reject(worker.__mcp_jobs_tool__(), &match?({_key, nil}, &1))
    else
      []
    end
  end
end
