defmodule MCPOban.ArgsSchemaTest do
  use ExUnit.Case, async: true

  alias MCPOban.Test.{PlainWorker, ProWorker}

  test "builds a JSON Schema from an Oban Pro args_schema" do
    assert MCPOban.ArgsSchema.from_worker(ProWorker) == %{
             "type" => "object",
             "additionalProperties" => false,
             "required" => ["id", "name", "data"],
             "properties" => %{
               "id" => %{"type" => "integer"},
               "name" => %{"type" => "string"},
               "mode" => %{
                 "type" => "string",
                 "enum" => ["enabled", "disabled"],
                 "default" => "enabled"
               },
               "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
               "at" => %{"type" => "string", "format" => "date-time"},
               "xtra" => %{},
               "data" => %{
                 "type" => "object",
                 "additionalProperties" => false,
                 "required" => ["office_id"],
                 "properties" => %{
                   "office_id" => %{"type" => "string", "format" => "uuid"},
                   "has_notes" => %{"type" => "boolean", "default" => false}
                 }
               },
               "addresses" => %{
                 "type" => "array",
                 "items" => %{
                   "type" => "object",
                   "additionalProperties" => false,
                   "properties" => %{"city" => %{"type" => "string"}}
                 }
               }
             }
           }
  end

  test "returns nil for a worker without args_schema" do
    assert MCPOban.ArgsSchema.from_worker(PlainWorker) == nil
  end

  test "the tools list uses the Pro schema unless input_schema is given" do
    assert [
             %{input_schema: %{"required" => ["id", "name", "data"]}},
             %{input_schema: %{"type" => "object"} = given}
           ] =
             MCPOban.ExMCP.__tools__([
               ProWorker,
               {ProWorker, name: "pro_override", input_schema: %{"type" => "object"}}
             ])

    assert given == %{"type" => "object"}
  end

  test "arguments are checked against the Pro schema" do
    [spec] = MCPOban.ExMCP.__tools__([ProWorker])

    assert {:ok, %{"isError" => true, "content" => [%{"text" => text}]}, :state} =
             MCPOban.ExMCP.__call_tool__(
               [spec],
               "pro_worker",
               %{"id" => 1, "extra" => true},
               :state,
               []
             )

    assert text =~ "name"
    assert text =~ "data"
  end
end
