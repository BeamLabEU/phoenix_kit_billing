defmodule PhoenixKitBilling.CoreApiContractTest do
  @moduledoc """
  Guards the PhoenixKit core API surface declared in
  `PhoenixKitBilling.CoreCompat` against whichever core actually resolved.

  `mix.exs` requires `phoenix_kit ~> 2.0`, so `mix deps.update phoenix_kit` can
  still pull a minor that moved something billing calls. Without this test that
  shows up as an `UndefinedFunctionError` in whichever LiveView a user opened
  first. With it, `mix test` names the functions.

  The declaration is also a claim about billing's own source: a call site added
  against a core function nobody listed is invisible to this guard, so the last
  test re-derives the list from the source and fails when they diverge.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitBilling.CoreCompat

  describe "declared core surface against the resolved phoenix_kit" do
    test "every unguarded call exists" do
      assert CoreCompat.missing_runtime_calls() == [],
             """
             phoenix_kit #{CoreCompat.core_version() || "(unloaded)"} does not export \
             everything billing calls without a guard. These call sites raise at runtime:

             #{format(CoreCompat.missing_runtime_calls())}

             Port the call sites, or pin phoenix_kit back in mix.exs. If core renamed \
             something, update PhoenixKitBilling.CoreCompat in the same commit.
             """
    end

    test "every guarded call exists" do
      assert CoreCompat.missing_optional_calls() == [],
             """
             phoenix_kit #{CoreCompat.core_version() || "(unloaded)"} is missing core \
             functions billing guards with `Code.ensure_loaded?/1`. Nothing crashes — \
             the features behind them just stop happening, which is why this is a test \
             and not a runtime error:

             #{format(CoreCompat.missing_optional_calls())}
             """
    end

    test "an installed sibling package still exports what billing applies on it" do
      assert CoreCompat.missing_sibling_calls() == [],
             """
             A sibling phoenix_kit_* package is installed but no longer exports what \
             billing calls on it through `apply/3`:

             #{format(CoreCompat.missing_sibling_calls())}

             Not having the sibling installed at all is fine and is not what this \
             asserts — the module is loaded here, so the call would raise.
             """
    end

    test "every `use`d and `import`ed core module loads" do
      assert CoreCompat.missing_compile_time_modules() == [],
             """
             Core modules billing `use`s or `import`s are not loadable:

             #{format(CoreCompat.missing_compile_time_modules())}

             Reaching this assertion at all is odd — a missing one of these normally \
             fails the build first. A dynamically-resolved module or a stale build \
             would explain it.
             """
    end
  end

  describe "the declaration itself" do
    test "lists no function twice and stays sorted by module" do
      calls = CoreCompat.runtime_calls() ++ CoreCompat.optional_calls()

      assert calls == Enum.uniq(calls),
             "duplicate entries in CoreCompat: #{format(calls -- Enum.uniq(calls))}"

      modules = CoreCompat.compile_time_modules()
      assert modules == Enum.uniq(modules)
    end

    test "covers every core call in billing's own source" do
      declared = MapSet.new(CoreCompat.runtime_calls() ++ CoreCompat.optional_calls())

      undeclared =
        source_core_calls()
        |> Enum.reject(&MapSet.member?(declared, &1))
        |> Enum.sort()

      assert undeclared == [],
             """
             These calls into PhoenixKit core are made by billing's source but are not \
             declared in PhoenixKitBilling.CoreCompat, so no core upgrade would flag them:

             #{format(undeclared)}

             Add each to `@runtime_calls` (unguarded) or `@optional_calls` (behind an \
             existence guard).
             """
    end
  end

  # Re-derives the core call sites from billing's AST: every remote call whose
  # module resolves — through the file's own aliases — to a PhoenixKit* module.
  # Pipes are counted with their piped-in argument, matching real arity.
  defp source_core_calls do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.flat_map(&calls_in_file/1)
    |> Enum.uniq()
  end

  defp calls_in_file(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()
    aliases = aliases_in(ast)

    {_, calls} =
      Macro.prewalk(ast, [], fn
        # `arg |> Mod.fun(rest)` — the pipe contributes one argument. The call
        # node is replaced by its parts rather than kept, because prewalk would
        # otherwise descend into it and record the same call a second time at
        # its written arity (`Tab.new!/0` for a piped `|> Tab.new!()`). The
        # piped-in expression and the remaining arguments stay in the tree so
        # calls nested inside them are still found.
        {:|>, _, [piped, {{:., _, [{:__aliases__, _, mods}, fun]}, _, args}]}, acc
        when is_atom(fun) and is_list(args) ->
          {{:__block__, [], [piped | args]}, add_call(acc, mods, aliases, fun, length(args) + 1)}

        {{:., _, [{:__aliases__, _, mods}, fun]}, _, args} = node, acc
        when is_atom(fun) and is_list(args) ->
          {node, add_call(acc, mods, aliases, fun, length(args))}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  defp add_call(acc, mods, aliases, fun, arity) do
    case resolve(mods, aliases) do
      nil -> acc
      module -> [{module, fun, arity} | acc]
    end
  end

  defp aliases_in(ast) do
    {_, acc} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, mods}]} = node, acc when is_list(mods) ->
          {node, Map.put(acc, List.last(mods), Module.concat(mods))}

        {:alias, _, [{:__aliases__, _, mods}, opts]} = node, acc when is_list(mods) ->
          {node, Map.put(acc, alias_shortcut(opts, mods), Module.concat(mods))}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp alias_shortcut(opts, mods) when is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _, as_mods} -> List.last(as_mods)
      _ -> List.last(mods)
    end
  end

  defp alias_shortcut(_opts, mods), do: List.last(mods)

  # Billing's own modules and the `PhoenixKit.Modules.Billing.*` compat shims are
  # not core surface — the shims are this package's own code under a core-owned
  # namespace, and `compat_delegate_test.exs` already guards them.
  defp resolve([head | rest], aliases) do
    module =
      case Map.fetch(aliases, head) do
        {:ok, expanded} -> Module.concat([expanded | rest])
        :error -> Module.concat([head | rest])
      end

    name = inspect(module)

    cond do
      String.starts_with?(name, "PhoenixKitBilling") -> nil
      String.starts_with?(name, "PhoenixKit.Modules.Billing") -> nil
      String.starts_with?(name, "PhoenixKit") -> module
      true -> nil
    end
  end

  defp resolve(_mods, _aliases), do: nil

  defp format(entries) do
    Enum.map_join(entries, "\n", fn
      {module, fun, arity} -> "  - #{inspect(module)}.#{fun}/#{arity}"
      module -> "  - #{inspect(module)}"
    end)
  end
end
