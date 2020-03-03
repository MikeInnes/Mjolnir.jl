rename(env, ex) = IRTools.prewalk(
  x -> x isa GlobalRef ? getfield(x.mod, x.name) :
  x isa Variable ? env[x] : x, ex)

returntype(ir) = exprtype(ir, returnvalue(IRTools.blocks(ir)[end]))

function copyblock!(ir::IR, b)
  c = IRTools.block!(ir)
  env = Dict()
  for (arg, T) in zip(arguments(b), argtypes(b))
    env[arg] = argument!(c, nothing, T, insert = false)
  end
  for (v, st) in b
    env[v] = push!(c, rename(env, st))
  end
  for br in IRTools.branches(b)
    push!(branches(c), rename(env, br))
  end
  return c
end

function abstract_group(cfg, i)
  j = IRTools.Inner.idoms(cfg', entry = length(cfg))[i]
  group = Int[]
  group!(b) =
    (b == j || b in group) || (push!(group, b); foreach(group!, cfg[b]))
  foreach(group!, cfg[i])
  return sort!(group), j
end

function extract_group(bl)
  out = IR()
  args = filter(x -> x isa Variable, union(arguments.(branches(block(bl.ir, bl.id)))...))
  args = union(args, filter(x -> x != nothing, map(x -> x.condition, branches(block(bl.ir, bl.id)))))
  innerargs = Dict(a => argument!(out, Union{}) for a in args)
  for br in branches(block(bl.ir, bl.id))
    push!(branches(block(out, 1)), rename(innerargs, br))
  end
  bs, after = abstract_group(CFG(bl.ir), bl.id)
  bmap = Dict()
  for b in bs
    bmap[b] = copyblock!(out, block(bl.ir, b)).id
  end
  ret = IRTools.block!(out)
  bmap[after] = ret.id
  for (arg, T) in zip(arguments(block(bl.ir, after)), argtypes(block(bl.ir, after)))
    argument!(ret, nothing, T, insert = false)
  end
  for b in blocks(out), (i, br) in enumerate(branches(b))
    branches(b)[i] = IRTools.Branch(br, block = bmap[br.block])
  end
  IRTools.domorder!(out)
  return out, args, after
end

function inline!(out, ir, args)
  env = Dict(zip(arguments(ir), args))
  before = blocks(out)[end]
  for br in branches(block(ir, 1))
    push!(branches(before), rename(env, br))
  end
  bmap = Dict()
  for bl in blocks(ir)[2:end]
    bmap[bl.id] = copyblock!(out, bl).id
  end
  for b in before.id:blocks(out)[end].id, (i, br) in enumerate(branches(block(out, b)))
    branches(block(out, b))[i] = IRTools.Branch(br, block = bmap[br.block])
  end
end

function abstract!(P, out, bl, env)
  ir, args, after = extract_group(bl)
  for i = 1:length(args)
    argtypes(ir)[i] = exprtype(out, rename(env, args[i]))
  end
  infer!(Inference(Frame(ir), P))
  inline!(out, ir, rename.((env,), args))
  for (k, v) in zip(arguments(block(bl.ir, after)), arguments(blocks(out)[end]))
    env[k] = v
  end
  return after
end

function openbranches(out, env, bl)
  brs = []
  for br in branches(bl)
    br.condition == nothing && (push!(brs, br); break)
    cond = exprtype(out, env[br.condition])
    cond == Const(true) && continue
    cond == Const(false) && (push!(brs, br); break)
    push!(brs, br)
  end
  return brs
end

_nodetype(x, T::AType) = T
_nodetype(x, T::Type) = Node{T}(x)
nodetype(ir::IR, x) = _nodetype(x, exprtype(ir, x))

function traceblock!(P, out, env, bl)
  for (k, v) in bl
    ex = v.expr
    if isexpr(ex, :call)
      Ts = map(v -> nodetype(out, rename(env, v)), ex.args)
      Ts[1] === Const(Base.not_int) && (Ts[1] = Const(!))
      if (T = partial(P, Ts...)) != nothing
        if T isa Node
          env[k] = T.value
        else
          env[k] = push!(out, stmt(rename(env, v.expr), type = T))
        end
      else
        env[k] = tracecall!(P, out, rename(env, ex).args, Ts)
      end
    elseif isexpr(ex, :meta)
    elseif isexpr(ex)
      error("Can't trace through $(ex.head) expression")
    else
      env[k] = ex
    end
  end
end

function trace!(P, out, ir, args)
  if ir.meta.method.isva
    nargs = ir.meta.method.nargs
    splat = args[nargs:end]
    splat = push!(out, stmt(xcall(tuple, splat...),
                            type = ptuple(nodetype.((out,), splat)...)))
    args = [args[1:nargs-1]..., splat]
  end
  env = Dict{Any,Any}(zip(arguments(ir), args))
  bl = 1
  while true
    traceblock!(P, out, env, block(ir, bl))
    brs = openbranches(out, env, block(ir, bl))
    if length(brs) == 1
      isreturn(brs[1]) && return rename(env, returnvalue(brs[1]))
      bl = brs[1].block
      foreach((a, b) -> env[a] = rename(env, b), arguments(block(ir, bl)), arguments(brs[1]))
    else
      bl = abstract!(P, out, block(ir, bl), env)
    end
  end
end

function tracecall!(P, tr, args, Ts)
  # @show Ts
  ir = IR(widen.(Ts)...)
  ir == nothing && error("No IR for $(Tuple{widen.(Ts)...})")
  ir = ir |> merge_returns! |> prepare_ir!
  trace!(P, tr, ir, args)
end

function trace(P, Ts...)
  tr = IR()
  args = [argument!(tr, T) for T in Ts]
  return!(tr, tracecall!(P, tr, args, Ts))
  return cleanup!(tr)
end

atype(T::AType) = T
atype(x) = Const(x)

function tracem(P, ex)
  @capture(ex, f_(args__)) || error("@trace f(args...)")
  :(trace($(esc(P)), atype.(($(esc(f)), $(esc.(args)...)))...))
end

macro trace(P, ex)
  tracem(P, ex)
end

macro trace(ex)
  tracem(Defaults(), ex)
end
