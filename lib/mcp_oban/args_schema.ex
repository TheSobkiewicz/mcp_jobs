defmodule MCPOban.ArgsSchema do
  @moduledoc false

  # Builds a JSON Schema from the `args_schema` of an Oban Pro worker.
  # Oban Pro keeps the fields in `__args_schema__/0` as `{name, opts}` pairs.
  # The format is the same in Oban Pro 1.5 to 1.7.

  @spec from_worker(module()) :: map() | nil
  def from_worker(worker) do
    if Code.ensure_loaded?(worker) and function_exported?(worker, :__args_schema__, 0) do
      object(worker.__args_schema__())
    end
  end

  defp object(fields) do
    required =
      for {name, opts} <- fields, Keyword.get(opts, :required, false), do: to_string(name)

    schema = %{
      "type" => "object",
      "properties" => Map.new(fields, fn {name, opts} -> {to_string(name), property(opts)} end),
      "additionalProperties" => false
    }

    if required == [], do: schema, else: Map.put(schema, "required", required)
  end

  defp property(opts) do
    schema = opts |> Map.new() |> field()

    case Keyword.fetch(opts, :default) do
      {:ok, default} -> Map.put(schema, "default", json_value(default))
      :error -> schema
    end
  end

  defp field(%{type: :embed, cardinality: :one, module: module}),
    do: object(module.__args_schema__())

  defp field(%{type: :embed, cardinality: :many, module: module}),
    do: %{"type" => "array", "items" => object(module.__args_schema__())}

  defp field(%{type: :enum, values: values}), do: enum(values)

  defp field(%{type: {:array, :enum}, values: values}),
    do: %{"type" => "array", "items" => enum(values)}

  defp field(%{type: {:array, type}}), do: %{"type" => "array", "items" => type(type)}
  defp field(%{type: type}), do: type(type)

  defp enum(values) do
    names =
      Enum.map(values, fn
        {name, _value} -> to_string(name)
        name -> to_string(name)
      end)

    %{"type" => "string", "enum" => names}
  end

  defp type(type) when type in [:id, :integer], do: %{"type" => "integer"}
  defp type(type) when type in [:float, :decimal], do: %{"type" => "number"}
  defp type(:boolean), do: %{"type" => "boolean"}
  defp type(type) when type in [:string, :binary], do: %{"type" => "string"}
  defp type(type) when type in [:uuid, :binary_id], do: %{"type" => "string", "format" => "uuid"}
  defp type(:map), do: %{"type" => "object"}
  defp type({:map, type}), do: %{"type" => "object", "additionalProperties" => type(type)}
  defp type(:date), do: %{"type" => "string", "format" => "date"}
  defp type(type) when type in [:time, :time_usec], do: %{"type" => "string", "format" => "time"}

  defp type(type)
       when type in [:naive_datetime, :naive_datetime_usec, :utc_datetime, :utc_datetime_usec],
       do: %{"type" => "string", "format" => "date-time"}

  defp type(_term_or_unknown), do: %{}

  defp json_value(value) when is_boolean(value) or is_nil(value), do: value
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value), do: value
end
