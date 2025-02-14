defmodule Electric.Replication.Eval.Parser do
  alias Electric.Utils
  alias Electric.Replication.PostgresInterop.Casting
  import Electric.Replication.PostgresInterop.Casting
  alias Electric.Replication.Eval.Env
  alias Electric.Replication.Eval.Lookups
  alias Electric.Replication.Eval.Expr

  defmodule Const do
    defstruct [:value, :type, location: 0]
  end

  defmodule UnknownConst do
    defstruct [:value, location: 0]
  end

  defmodule Ref do
    defstruct [:path, :type, location: 0]
  end

  defmodule Func do
    defstruct [:args, :type, :implementation, :name, strict?: true, immutable?: true, location: 0]
  end

  @valid_types (Electric.Postgres.supported_types() ++
                  Electric.Postgres.supported_types_only_in_functions())
               |> Enum.map(&Atom.to_string/1)

  @type tree_part :: %Const{} | %Ref{} | %Func{}
  @type refs_map :: %{optional([String.t(), ...]) => Env.pg_type()}

  @spec parse_and_validate_expression(String.t(), refs_map(), Env.t()) ::
          {:ok, Expr.t()} | {:error, String.t()}
  def parse_and_validate_expression(query, refs \\ %{}, env \\ Env.new())
      when is_map(refs) and is_struct(env, Env) and is_binary(query) do
    with {:ok, %{stmts: stmts}} <- PgQuery.parse("SELECT 1 WHERE #{query}") do
      case stmts do
        [%{stmt: %{node: {:select_stmt, stmt}}}] ->
          case check_and_parse_stmt(stmt, refs, env) do
            {:ok, value} ->
              {:ok,
               %Expr{query: query, eval: value, returns: value.type, used_refs: find_refs(value)}}

            {:error, {loc, reason}} ->
              {:error, "At location #{loc}: #{reason}"}

            {:error, reason} ->
              {:error, reason}
          end

        _ ->
          {:error, ~s'unescaped ";" causing statement split'}
      end
    else
      {:error, %{cursorpos: loc, message: reason}} ->
        {:error, "At location #{loc}: #{reason}"}
    end
  end

  @spec parse_and_validate_expression!(String.t(), refs_map(), Env.t()) :: Expr.t()
  def parse_and_validate_expression!(query, refs \\ %{}, env \\ Env.new()) do
    {:ok, value} = parse_and_validate_expression(query, refs, env)
    value
  end

  @prefix_length String.length("SELECT 1 WHERE ")

  @spec check_and_parse_stmt(struct(), refs_map(), Env.t()) ::
          {:ok, tree_part()} | {:error, term()}
  defp check_and_parse_stmt(stmt, refs, env) do
    extra_suffixes =
      stmt
      |> Map.take([:from_clause, :window_clause, :group_clause, :sort_clause, :locking_clause])
      |> Enum.find(fn {_, value} -> value != [] end)

    if is_nil(extra_suffixes) do
      case do_parse_and_validate_tree(stmt.where_clause, refs, env) do
        {:error, {loc, reason}} -> {:error, {max(loc - @prefix_length, 0), reason}}
        {:ok, %UnknownConst{} = unknown} -> {:ok, infer_unknown(unknown)}
        value -> value
      end
    else
      {:error, "malformed query ending with SQL clauses"}
    end
  end

  @spec do_parse_and_validate_tree(struct(), map(), map()) ::
          {:ok, %UnknownConst{} | tree_part()}
          | {:error, {non_neg_integer(), String.t()}}
  defp do_parse_and_validate_tree(%PgQuery.Node{node: {_, node}}, refs, env),
    do: do_parse_and_validate_tree(node, refs, env)

  defp do_parse_and_validate_tree(%PgQuery.A_Const{isnull: true, location: loc}, _, _),
    do: {:ok, %UnknownConst{value: nil, location: loc}}

  defp do_parse_and_validate_tree(%PgQuery.A_Const{val: {:sval, struct}, location: loc}, _, _),
    do: {:ok, %UnknownConst{value: Map.fetch!(struct, :sval), location: loc}}

  defp do_parse_and_validate_tree(%PgQuery.A_Const{val: {kind, struct}, location: loc}, _, _),
    do: make_const(kind, Map.fetch!(struct, kind), loc)

  defp do_parse_and_validate_tree(%PgQuery.ColumnRef{fields: fields, location: loc}, refs, _) do
    ref = Enum.map(fields, &unwrap_node_string/1)

    case Map.fetch(refs, ref) do
      {:ok, type} ->
        {:ok, %Ref{path: ref, type: type, location: loc}}

      :error ->
        message = "unknown reference #{identifier(ref)}"

        message =
          if match?([_], ref) and is_map_key(refs, ["this", List.first(ref)]),
            do: message <> " - did you mean `this.#{List.first(ref)}`?",
            else: message

        {:error, {loc, message}}
    end
  end

  defp do_parse_and_validate_tree(
         %PgQuery.BoolExpr{args: args, boolop: bool_op} = expr,
         refs,
         env
       ) do
    with {:ok, args} <- Utils.map_while_ok(args, &do_parse_and_validate_tree(&1, refs, env)),
         {:ok, args} <- cast_unknowns(args, List.duplicate(:bool, length(args)), env) do
      case Enum.find(args, &(not Env.implicitly_castable?(env, &1.type, :bool))) do
        nil ->
          {fun, name} =
            case bool_op do
              :OR_EXPR -> {&Kernel.or/2, "or"}
              :AND_EXPR -> {&Kernel.and/2, "and"}
              :NOT_EXPR -> {&Kernel.not/1, "not"}
            end

          maybe_reduce(%Func{
            implementation: fun,
            name: name,
            type: :bool,
            args: args,
            location: expr.location
          })

        %{location: loc} = node ->
          {:error, {loc, "#{internal_node_to_error(node)} is not castable to bool"}}
      end
    end
  end

  defp do_parse_and_validate_tree(
         %PgQuery.TypeCast{arg: arg, type_name: type_name},
         refs,
         env
       ) do
    with {:ok, arg} <- do_parse_and_validate_tree(arg, refs, env),
         {:ok, type} <- get_type_from_pg_name(type_name) do
      case arg do
        %UnknownConst{} = unknown ->
          explicit_cast_const(infer_unknown(unknown), type, env)

        %{type: ^type} = subtree ->
          {:ok, subtree}

        %Const{} = known ->
          explicit_cast_const(known, type, env)

        %{type: _} = subtree ->
          as_dynamic_cast(subtree, type, env)
      end
    end
  catch
    {:error, {_loc, _message}} = error -> error
  end

  defp do_parse_and_validate_tree(%PgQuery.FuncCall{} = call, _, _)
       when call.agg_order != []
       when not is_nil(call.agg_filter)
       when not is_nil(call.over)
       when call.agg_within_group
       when call.agg_star
       when call.agg_distinct,
       do: {:error, {call.location, "aggregation is not supported in this context"}}

  defp do_parse_and_validate_tree(
         %PgQuery.FuncCall{args: args} = call,
         refs,
         env
       ) do
    with {:ok, choices} <- find_available_functions(call, env),
         {:ok, args} <- Utils.map_while_ok(args, &do_parse_and_validate_tree(&1, refs, env)) do
      with {:ok, concrete} <- Lookups.pick_concrete_function_overload(choices, args, env),
           {:ok, args} <- cast_unknowns(args, concrete.args, env),
           {:ok, args} <- cast_implicit(args, concrete.args, env) do
        concrete
        |> from_concrete(args)
        |> maybe_reduce()
      else
        {:error, {_loc, _msg}} = error ->
          error

        :error ->
          arg_list =
            Enum.map_join(args, ", ", fn
              %UnknownConst{} -> "unknown"
              %{type: type} -> to_string(type)
            end)

          {:error,
           {call.location,
            "Could not select a function overload for #{identifier(call.funcname)}(#{arg_list})"}}
      end
    end
  end

  # Next block of overloads matches on `A_Expr`, which is any operator call, as well as special syntax calls (e.g. `BETWEEN` or `ANY`).
  # They all treat lexpr and rexpr differently, so we're just deferring to a concrete function implementation here for clarity.
  defp do_parse_and_validate_tree(%PgQuery.A_Expr{kind: kind, location: loc} = expr, refs, env) do
    case {kind, expr.lexpr} do
      {:AEXPR_OP, nil} -> handle_unary_operator(expr, refs, env)
      {:AEXPR_OP, _} -> handle_binary_operator(expr, refs, env)
      # LIKE and ILIKE are expressed plainly as operators by the parser
      {:AEXPR_LIKE, _} -> handle_binary_operator(expr, refs, env)
      {:AEXPR_ILIKE, _} -> handle_binary_operator(expr, refs, env)
      {:AEXPR_DISTINCT, _} -> handle_distinct(expr, refs, env)
      {:AEXPR_IN, _} -> handle_in(expr, refs, env)
      _ -> {:error, {loc, "expression #{identifier(expr.name)} is not currently supported"}}
    end
  end

  defp do_parse_and_validate_tree(
         %PgQuery.NullTest{argisrow: false, location: loc} = test,
         refs,
         env
       ) do
    with {:ok, arg} <- do_parse_and_validate_tree(test.arg, refs, env) do
      arg =
        case arg do
          %UnknownConst{} = unknown -> infer_unknown(unknown)
          arg -> arg
        end

      func =
        if test.nulltesttype == :IS_NULL, do: &Kernel.is_nil/1, else: &(not Kernel.is_nil(&1))

      maybe_reduce(%Func{
        strict?: false,
        location: loc,
        args: [arg],
        implementation: func,
        type: :bool,
        name: Atom.to_string(test.nulltesttype)
      })
    end
  end

  defp do_parse_and_validate_tree(
         %PgQuery.BooleanTest{location: loc} = test,
         refs,
         env
       ) do
    with {:ok, arg} <- do_parse_and_validate_tree(test.arg, refs, env),
         {:ok, [arg]} <- cast_unknowns([arg], [:bool], env) do
      if arg.type == :bool do
        func =
          case test.booltesttype do
            :IS_TRUE -> &(&1 == true)
            :IS_NOT_TRUE -> &(&1 != true)
            :IS_FALSE -> &(&1 == false)
            :IS_NOT_FALSE -> &(&1 != false)
          end

        maybe_reduce(%Func{
          strict?: false,
          location: loc,
          args: [arg],
          implementation: func,
          type: :bool,
          name: Atom.to_string(test.booltesttype)
        })
      else
        operator = unsnake(Atom.to_string(test.booltesttype))
        {:error, {loc, "argument of #{operator} must be bool, not #{arg.type}"}}
      end
    end
  end

  # Explicitly fail on "sublinks" - subqueries are not allowed in any context here
  defp do_parse_and_validate_tree(%PgQuery.SubLink{location: loc}, _, _),
    do: {:error, {loc, "subqueries are not supported"}}

  # If nothing matched, fail
  defp do_parse_and_validate_tree(%type_module{} = node, _, _),
    do:
      {:error,
       {Map.get(node, :location, 0),
        "#{type_module |> Module.split() |> List.last()} is not supported in this context"}}

  defp get_type_from_pg_name(%PgQuery.TypeName{names: _, array_bounds: [_ | _]} = cast),
    do: {:error, {cast.location, "Electric currently doesn't support array types"}}

  defp get_type_from_pg_name(%PgQuery.TypeName{names: names, location: loc}) do
    case Enum.map(names, &unwrap_node_string/1) do
      ["pg_catalog", type_name] when type_name in @valid_types ->
        {:ok, String.to_existing_atom(type_name)}

      [type_name] when type_name in @valid_types ->
        {:ok, String.to_existing_atom(type_name)}

      type ->
        {:error, {loc, "unsupported type #{identifier(type)}"}}
    end
  end

  defp handle_unary_operator(%PgQuery.A_Expr{rexpr: rexpr, name: name} = expr, refs, env) do
    with {:ok, func} <- find_operator_func(name, [rexpr], expr.location, refs, env) do
      maybe_reduce(func)
    end
  end

  defp handle_binary_operator(%PgQuery.A_Expr{name: name} = expr, refs, env) do
    args = [expr.lexpr, expr.rexpr]

    with {:ok, func} <- find_operator_func(name, args, expr.location, refs, env) do
      maybe_reduce(func)
    end
  end

  defp handle_distinct(%PgQuery.A_Expr{kind: kind} = expr, refs, env) do
    args = [expr.lexpr, expr.rexpr]
    fun = if kind == :AEXPR_DISTINCT, do: :values_distinct?, else: :values_not_distinct?

    with {:ok, func} <- find_operator_func(["="], args, expr.location, refs, env),
         {:ok, reduced} <- maybe_reduce(func) do
      # This is suboptimal at evaluation time, in that it duplicates same argument sub-expressions
      # to be at this level, as well as at the `=` operator level. I'm not sure how else to model
      # this as functions, without either introducing functions as arguments (to pass in the operator impl),
      # or without special-casing the `distinct` clause.
      maybe_reduce(%Func{
        implementation: {Casting, fun},
        name: to_string(fun),
        type: :bool,
        args: func.args ++ [reduced],
        strict?: false
      })
    end
  end

  defp handle_in(%PgQuery.A_Expr{name: [name]} = expr, refs, env) do
    # This is "=" if it's `IN`, and "<>" if it's `NOT IN`.
    name = unwrap_node_string(name)

    # It can only be a list here because that's how PG parses SQL. It it's a subquery, then it wouldn't be `A_Expr`.
    {:list, %PgQuery.List{items: items}} = expr.rexpr.node

    with {:ok, comparisons} <-
           Utils.map_while_ok(
             items,
             &find_operator_func(["="], [expr.lexpr, &1], expr.location, refs, env)
           ),
         {:ok, comparisons} <- Utils.map_while_ok(comparisons, &maybe_reduce/1),
         {:ok, reduced} <- build_or_chain(comparisons, expr.location) do
      # x NOT IN y is exactly equivalent to NOT (x IN y)
      if name == "=",
        do: {:ok, reduced},
        else:
          maybe_reduce(%Func{
            implementation: &Kernel.not/1,
            name: "not",
            type: :bool,
            args: [reduced],
            location: expr.location
          })
    end
  end

  defp build_or_chain([head | tail], location) do
    Enum.reduce_while(tail, {:ok, head}, fn comparison, {:ok, acc} ->
      %Func{
        implementation: &Kernel.or/2,
        name: "or",
        type: :bool,
        args: [acc, comparison],
        location: location
      }
      |> maybe_reduce()
      |> case do
        {:ok, reduced} -> {:cont, {:ok, reduced}}
        error -> {:halt, error}
      end
    end)
  end

  # Returns an unreduced function so that caller has access to args
  @spec find_operator_func([String.t()], [term(), ...], non_neg_integer(), map(), Env.t()) ::
          {:ok, %Func{}} | {:error, {non_neg_integer(), String.t()}}
  defp find_operator_func(name, args, location, refs, env) do
    # Operators cannot have arity other than 1 or 2
    arity = if(match?([_, _], args), do: 2, else: 1)

    with {:ok, choices} <- find_available_operators(name, arity, location, env),
         {:ok, args} <- Utils.map_while_ok(args, &do_parse_and_validate_tree(&1, refs, env)),
         {:ok, concrete} <- Lookups.pick_concrete_operator_overload(choices, args, env),
         {:ok, args} <- cast_unknowns(args, concrete.args, env),
         {:ok, args} <- cast_implicit(args, concrete.args, env) do
      {:ok, from_concrete(concrete, args)}
    else
      {:error, {_loc, _msg}} = error -> error
      :error -> {:error, {location, "Could not select an operator overload"}}
    end
  end

  defp explicit_cast_const(%Const{type: type, value: value} = const, target_type, %Env{} = env) do
    with {:ok, %Func{} = func} <- as_dynamic_cast(const, target_type, env) do
      case try_applying(%{func | args: [value]}) do
        {:ok, const} ->
          {:ok, const}

        {:error, _} ->
          {:error,
           {const.location,
            "could not cast value #{inspect(value)} from #{type} to #{target_type}"}}
      end
    end
  end

  defp find_available_functions(%PgQuery.FuncCall{} = call, %{funcs: funcs}) do
    name = identifier(call.funcname)
    arity = length(call.args)

    case Map.fetch(funcs, {name, arity}) do
      {:ok, options} -> {:ok, options}
      :error -> {:error, {call.location, "unknown or unsupported function #{name}/#{arity}"}}
    end
  end

  defp find_available_operators(name, arity, location, %{operators: operators})
       when arity in [1, 2] do
    name = identifier(name)

    case Map.fetch(operators, {name, arity}) do
      {:ok, options} ->
        {:ok, options}

      :error ->
        {:error,
         {location, "unknown #{if arity == 1, do: "unary", else: "binary"} operator #{name}"}}
    end
  end

  defp find_cast_function(%Env{} = env, from_type, to_type) do
    case Map.fetch(env.implicit_casts, {from_type, to_type}) do
      {:ok, :as_is} ->
        {:ok, :as_is}

      {:ok, {module, fun}} ->
        {:ok, {module, fun}}

      :error ->
        case {from_type, to_type} do
          {:text, to_type} -> find_cast_in_function(env, to_type)
          {from_type, :text} -> find_cast_out_function(env, from_type)
          {from_type, to_type} -> find_explicit_cast(env, from_type, to_type)
        end
    end
  end

  defp find_cast_in_function(env, to_type) do
    case Map.fetch(env.funcs, {"#{to_type}", 1}) do
      {:ok, [%{args: [:text], implementation: impl}]} -> {:ok, impl}
      _ -> :error
    end
  end

  defp find_cast_out_function(env, to_type) do
    case Map.fetch(env.funcs, {"#{to_type}out", 1}) do
      {:ok, [%{args: [^to_type], implementation: impl}]} -> {:ok, impl}
      _ -> :error
    end
  end

  defp find_explicit_cast(env, from_type, to_type),
    do: Map.fetch(env.explicit_casts, {from_type, to_type})

  @spec as_dynamic_cast(tree_part(), Env.pg_type(), Env.t()) ::
          {:ok, tree_part()} | {:error, {non_neg_integer(), String.t()}}
  defp as_dynamic_cast(%{type: type, location: loc} = arg, target_type, env) do
    case find_cast_function(env, type, target_type) do
      {:ok, :as_is} ->
        {:ok, %{arg | type: target_type}}

      {:ok, impl} ->
        {:ok,
         %Func{
           location: loc,
           type: target_type,
           args: [arg],
           implementation: impl,
           name: "#{type}_to_#{target_type}"
         }}

      :error ->
        {:error, {loc, "unknown cast from type #{type} to type #{target_type}"}}
    end
  end

  defp cast_implicit(processed_args, arg_list, env) do
    {:ok,
     Enum.zip_with(processed_args, arg_list, fn
       %{type: type} = arg, type ->
         arg

       %{type: from_type} = arg, to_type ->
         case Map.fetch!(env.implicit_casts, {from_type, to_type}) do
           :as_is ->
             arg

           impl ->
             %Func{
               location: arg.location,
               type: to_type,
               args: [arg],
               implementation: impl,
               name: "#{from_type}_to_#{to_type}"
             }
             |> maybe_reduce()
             |> case do
               {:ok, val} -> val
               error -> throw(error)
             end
         end
     end)}
  catch
    {:error, {_loc, _message}} = error -> error
  end

  defp cast_unknowns(processed_args, arg_list, env) do
    {:ok,
     Enum.zip_with(processed_args, arg_list, fn
       %UnknownConst{value: nil, location: loc}, type ->
         %Const{type: type, value: nil, location: loc}

       %UnknownConst{value: value, location: loc}, type ->
         case Env.parse_const(env, value, type) do
           {:ok, value} -> %Const{type: type, location: loc, value: value}
           :error -> throw({:error, {loc, "invalid syntax for type #{type}: #{value}"}})
         end

       arg, _ ->
         arg
     end)}
  catch
    {:error, {_loc, _message}} = error -> error
  end

  defp infer_unknown(%UnknownConst{value: nil, location: loc}),
    do: %Const{type: :unknown, value: nil, location: loc}

  defp infer_unknown(%UnknownConst{value: value, location: loc}),
    do: %Const{type: :text, value: value, location: loc}

  defp make_const(kind, value, loc) do
    case {kind, value} do
      {:ival, value} when is_pg_int4(value) ->
        {:ok, %Const{type: :int4, value: value, location: loc}}

      {:ival, value} when is_pg_int8(value) ->
        {:ok, %Const{type: :int8, value: value, location: loc}}

      {:fval, value} ->
        {:ok, %Const{type: :numeric, value: value, location: loc}}

      {:boolval, value} ->
        {:ok, %Const{type: :bool, value: value, location: loc}}

      {:sval, value} ->
        {:ok, %Const{type: :text, value: value, location: loc}}

      {:bsval, _} ->
        {:error, {loc, "BitString values are not supported"}}
    end
  end

  defp from_concrete(concrete, args) do
    # Commutative overload is an operator overload that accepts same arguments
    # as normal overload but in reverse order. This only matters/happens when
    # arguments are of different types (e.g. `date + int8`)
    commutative_overload? = Map.get(concrete, :commutative_overload?, false)

    %Func{
      implementation: concrete.implementation,
      name: concrete.name,
      args: if(commutative_overload?, do: Enum.reverse(args), else: args),
      type: concrete.returns,
      # These two fields are always set by macro generation, but not always in tests
      strict?: Map.get(concrete, :strict?, true),
      immutable?: Map.get(concrete, :immutable?, true)
    }
  end

  # Try reducing the function if all it's arguments are constants
  # but only immutable functions (although currently all functions are immutable)
  @spec maybe_reduce(%Func{}) ::
          {:ok, %Func{} | %Const{}} | {:error, {non_neg_integer(), String.t()}}
  defp maybe_reduce(%Func{immutable?: false} = func), do: {:ok, func}

  defp maybe_reduce(%Func{args: args} = func) do
    {args, {any_nils?, all_const?}} =
      Enum.map_reduce(args, {false, true}, fn
        %Const{value: nil}, {_any_nils?, all_const?} -> {nil, {true, all_const?}}
        %Const{value: value}, {any_nils?, all_const?} -> {value, {any_nils?, all_const?}}
        _, {any_nils?, _all_const?} -> {:not_used, {any_nils?, false}}
      end)

    cond do
      # Strict functions will always collapse to nil
      func.strict? and any_nils? ->
        {:ok, %Const{type: func.type, location: func.location, value: nil}}

      # Otherwise we don't have enough information to run this at "compile time"
      not all_const? ->
        {:ok, func}

      # But if all are consts and either function is not strict or there are no nils, we can try applying
      true ->
        try_applying(%Func{func | args: args})
    end
  end

  defp try_applying(%Func{args: args, implementation: impl} = func) do
    value =
      case impl do
        {module, function} -> apply(module, function, args)
        function -> apply(function, args)
      end

    {:ok, %Const{value: value, type: func.type, location: func.location}}
  rescue
    e ->
      IO.puts(Exception.format(:error, e, __STACKTRACE__))
      {:error, {func.location, "Failed to apply function to constant arguments"}}
  end

  defp identifier(ref) do
    case Enum.map(ref, &wrap_identifier/1) do
      ["pg_catalog", func] -> func
      identifier -> Enum.join(identifier, ".")
    end
  end

  defp wrap_identifier(%PgQuery.Node{} = node),
    do: node |> unwrap_node_string() |> wrap_identifier()

  defp wrap_identifier(%PgQuery.String{sval: val}), do: wrap_identifier(val)

  defp wrap_identifier(ref) when is_binary(ref) do
    if String.match?(ref, ~r/^[[:lower:]_][[:lower:][:digit:]_]*$/u) do
      ref
    else
      ~s|"#{String.replace(ref, ~S|"|, ~S|""|)}"|
    end
  end

  defp internal_node_to_error(%Ref{path: path, type: type}),
    do: "reference #{identifier(path)} of type #{type}"

  defp internal_node_to_error(%Func{type: type, name: name}),
    do: "function #{name} returning #{type}"

  defp find_refs(tree, acc \\ %{})
  defp find_refs(%Const{}, acc), do: acc
  defp find_refs(%Ref{path: path, type: type}, acc), do: Map.put_new(acc, path, type)
  defp find_refs(%Func{args: args}, acc), do: Enum.reduce(args, acc, &find_refs/2)

  defp unsnake(string) when is_binary(string), do: :binary.replace(string, "_", " ", [:global])

  def unwrap_node_string(%PgQuery.Node{node: {:string, %PgQuery.String{sval: sval}}}), do: sval

  def unwrap_node_string(%PgQuery.Node{node: {:a_const, %PgQuery.A_Const{val: {:sval, sval}}}}),
    do: unwrap_node_string(sval)
end
