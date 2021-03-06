## gradient function defintions

## GRAD RESULT

struct GradResult
    tape::Tape
    gvars::Dict{Int, Any}  # gradient vars: argid -> gradient var
end


function GradResult(tape::Tape)
    gvars = Dict{Int,Any}()
    # struct fields
    for (argid, dct) in tape.sfields
        gvars[argid] = Dict(field_path => tape.derivs[var_id]
                            for (field_path, var_id) in dct
                            if haskey(tape.derivs, var_id))  # not all fields may have derivatives
    end
    # other arguments
    struct_arg_ids = Set(keys(tape.sfields))
    for op in tape
        if op isa Input && !in(op.argid, struct_arg_ids)
            gvars[op.argid] = tape.derivs[op.var.id]
        end
    end
    return GradResult(tape, gvars)
end


Base.show(io::IO, g::GradResult) = print(io, "GradResult($(length(g.gvars)))")

function getindex(g::GradResult, argid::Int)
    tape = g.tape
    gvar = g.gvars[argid]
    if isa(gvar, Dict)
        return Dict(f => tape[id].var.val for (f, id) in gvar)
    else
        return tape[gvar].var.val
    end
end


## GRAD

getderiv(tape::Tape, id::Int) = tape[tape.derivs[id]].var
getderiv(tape::Tape, var::TAny) = getderiv(tape, var.id)
setderiv!(tape::Tape, var_id::Int, grad_var_id::Int) = (tape.derivs[var_id] = grad_var_id)
setderiv!(tape::Tape, var::TAny, grad_var::TAny) = (tape.derivs[var.id] = grad_var.id)


function rev_step!(op::Union{Call, Bcast}, i::Int)
    tape = op.var.tape
    y = op.var
    x = op.args[i]
    dy = getderiv(tape, y)
    dx = grad!(dy, Val(i), op)
    if !haskey(tape.derivs, x.id)
        setderiv!(tape, x, dx)
    else
        old_dx = getderiv(tape, x)
        new_dx = record!(tape, Call, +, (dx, old_dx))
        setderiv!(tape, x, new_dx)
    end
end


function back!(tape::Tape)
    # z - final variable, y - resulting variable of current op, x - dependencies of y
    # dy - derivative of z w.r.t. y
    z = tape[end].var
    # using Float32 for seed since for 64-bit args it will be expanded anyway
    dy = record!(tape, Constant, 1.0f0)
    # set initial derivative value
    tape.derivs[z.id] = dy.id
    for op in reverse(tape.ops[1:end-1])
        if op isa Call || op isa Bcast
            for i=1:length(op.args)
                # println("op = $op; i = $i")
                # backpropagate only non-constant tracked vars
                arg_op = tape[getid(op.args[i])]
                if op.args[i] isa TAny && !isa(arg_op, Constant)
                    rev_step!(op, i)
                end
            end
        end
    end
end


function make_tracked_args(tape::Tape, args...)
    targs = []
    for (argid, arg) in enumerate(args)
        if isstruct(arg)
            targ = record_struct!(tape, arg, argid)
        else
            targ = record!(tape, Input, arg; argid=argid)
        end
        push!(targs, targ)
    end
    return targs
end


"""
For each input that has a derivative on this tape check if the derivative
has the same size as the input.
"""
function check_deriv_sizes(tape::Tape)
    for (var_id, grad_var_id) in tape.derivs
        var_size = size(getvalue(tape[var_id]))
        grad_var_size = size(getvalue(tape[grad_var_id]))
        if  var_size != grad_var_size
            @warn "Gradient %$grad_var_id has size $grad_var_size, " *
                "but original variable %$var_id has size $var_size"
        end
    end
end


function _grad(f::Function, args...)
    tape = Tape(guess_device(args))
    # wrap args into tracked data
    targs = make_tracked_args(tape, args...)
    # execute function to fill in the tape
    tres = f(targs...)
    tape.resultid = getid(tres)
    # backpropagate gradients
    back!(tape)
    # consistency check
    check_deriv_sizes(tape)
    # construct GradResult object that wraps tape and provide accessors for computed derivatives
    return tres.val, GradResult(tape)
end


const GRAD_CACHE = Dict{Any, Tape}()


"""
Find gradient of `f` w.r.t. its arguments.
Example:

    val, g = grad(sum, rand(3))

where:
  - val is the value of `f` at this point
  - g::GradResult is a collection of gradients

GradResult is indexed by argument index and contains gradients
in a format most suitable for that argument, namely:

  - for arrays: arrays of the same type and size
  - for reals: reals
  - for mutable structs: dictionary of {(:field, :path) => value} pairs.

All gradients can be applied to original variables using `update!()` function.
"""
function grad(f::Function, args...; static=true)
    if static
        # key conists of function type and type of argument (for structs) or its size
        cache_key = (f, ([isstruct(arg) ? typeof(arg) : size(arg) for arg in args]...,))
        if haskey(GRAD_CACHE, cache_key)
            tape = GRAD_CACHE[cache_key]
            play!(tape, args...)
            return getvalue(tape[tape.resultid]), GradResult(tape)
        else
            val, g = _grad(f, args...)
            compile!(g.tape)
            GRAD_CACHE[cache_key] = g.tape
            return val, g
        end
    else
        return _grad(f, args...)
    end
end
