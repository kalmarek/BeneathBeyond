import AlphaZero.GI

struct CapsSpec{N} <: GI.AbstractGameSpec end

board_shape(::Type{CapsSpec{N}}) where {N} = ntuple(_ -> 3, N)

# Optionally input characteristic p (for now it is 3)
mutable struct CapsEnv{N} <: GI.AbstractGameEnv
    board::BitArray{N}
    history::Vector{UInt16}
    # possible_moves::Vector{UInt16}
end

board(g::CapsEnv) = g.board
history(g::CapsEnv) = g.history

function GI.init(
    ::CapsSpec{N},
    state = (board = falses(board_shape(CapsSpec{N})), history = UInt16[]),
) where {N}
   # Todo: Better upper bound
    sizehint!(state.history, 3^N-N)
    return CapsEnv{N}(copy(state.board), copy(state.history))
end

GI.spec(::CapsEnv{N}) where {N} = CapsSpec{N}()

GI.two_players(::CapsSpec) = false

function GI.set_state!(g::CapsEnv, state)
    g.board = copy(state.board)
    g.history = copy(state.history)
end

#####
##### Game API
#####

GI.actions(::CapsSpec{N}) where {N} = 1:3^N

GI.actions_mask(g::CapsEnv) = vec(.~(board(g)))

GI.current_state(g::CapsEnv) = (board = copy(board(g)), history = copy(history(g)))

GI.white_playing(::CapsEnv) = true

GI.game_terminated(g::CapsEnv) = all(board(g))

GI.white_reward(g::CapsEnv) =
    isempty(history(g)) ? 0.0 : length(history(g))

function third_point_on_line(p1, p2)
   return ((p1 .+ p2) .*(-1)) .% 3
end

Base.@propagate_inbounds function Base.push!(g::CapsEnv, n::Integer)
    @boundscheck checkbounds(board(g), n)

    g.board[n] = true
    q = Tuple(CartesianIndices(g.board)[n])
    for pIndex in history(g)
       p = Tuple(CartesianIndices(g.board)[pIndex])
       pq = third_point_on_line(p, q)
       g.board[pq] = true
    end

    push!(g.history, n)
    return g
end

GI.play!(g::CapsEnv, action) = push!(g, action)

GI.heuristic_value(g::CapsEnv) = isempty(history(g)) ? 0.0 : -float(sum(history(g))) # Polymake.triangulation_size(g.bb)

#####
##### Machine Learning API
#####

function GI.vectorize_state(::CapsSpec{N}, state) where {N}
    res = zeros(Float32, 2^N + 3^N)
    @inbounds res[1:2^N] .= vec(state.board)
    @inbounds res[2^N+1:2^N+length(state.history)] .= state.history
    return res
end

#####
##### Symmetries
#####

struct AllPerms{T<:Integer}
    all::Int
    c::Vector{T}
    elts::Vector{T}

    AllPerms(n::T) where T = new{T}(factorial(n), ones(T, n), collect(1:n))
end

Base.eltype(::Type{AllPerms{T}}) where T = Vector{T}
Base.length(A::AllPerms) = A.all

@inline Base.iterate(A::AllPerms) = (A.elts, 1)

@inline function Base.iterate(A::AllPerms, count)
    count >= A.all && return nothing

    k,n = 0,1

    @inbounds while true
        if A.c[n] < n
            k = ifelse(isodd(n), 1, A.c[n])
            A.elts[k], A.elts[n] = A.elts[n], A.elts[k]
            A.c[n] += 1
            return A.elts, count + 1
        else
            A.c[n] = 1
            n += 1
        end
    end
end

Base.@propagate_inbounds function Base.permutedims(
    cidx::CartesianIndex{N},
    perm::AbstractVector{<:Integer},
) where N
    @boundscheck length(perm) == N
    @boundscheck all(i -> 0 < perm[i] <= length(cidx), 1:length(cidx))
    return CartesianIndex(ntuple(i -> @inbounds(cidx[perm[i]]), Val(N)))
end

function action_homomorphism(σ::AbstractVector{<:Integer}, cids, lids)
    return Int[lids[permutedims(cids[a], σ)] for a in vec(lids)]
end

function action_on_gamestate(
    state,
    σ::AbstractVector{<:Integer};
    cids = CartesianIndices(state.board),
    lids = LinearIndices(state.board),
)
    p = action_homomorphism(invperm(σ), cids, lids)
    state_p =
        (board = permutedims(state.board, σ), history = UInt16[p[h] for h in state.history])
    return (state_p, convert(Vector{Int}, p))
end

# function GI.symmetries(::CapsSpec{N}, state) where {N}
#     cids = CartesianIndices(state.board)
#     lids = LinearIndices(state.board)
# 
#     return Tuple{typeof(state), Vector{Int}}[
#         action_on_gamestate(state, σ, cids = cids, lids = lids) for σ in Iterators.rest(AllPerms(N), 1)
#         ]
# end

#####
##### Interaction API
#####

using Crayons

function GI.action_string(::CapsSpec{N}, action) where {N}
    ci = CartesianIndices(board_shape(CapsSpec{N}))[action]
    return join(Tuple(ci) .- 1, "")
end

function GI.parse_action(::CapsSpec{N}, str) where {N}
    if length(str) <= ceil(log10(N))
        k = parse(Int, str)
        return k
    else
        ci = map(x -> (x == '0' ? 1 : 2), collect(str)[1:N])
        k = getindex(LinearIndices(board_shape(CapsSpec{N})), ci...)
        return k
    end
end

function GI.read_state(::CapsSpec{N}) where {N}
    throw("Not Implemented")
end

function GI.render(g::CapsEnv{N}; with_position_names = true, botmargin = true) where {N}

    println("current value: ", GI.heuristic_value(g), "\n")

    st = GI.current_state(g)
    amask = GI.actions_mask(g)
    k = ceil(Int, log10(2^N))
    for action in GI.actions(GI.spec(g))
        color =
        amask[action] ? crayon"bold fg:light_gray" : crayon"fg:dark_gray"
        with_position_names && print(color, rpad("$action", k + 2), " | ")
        println(color, GI.action_string(GI.spec(g), action), crayon"reset")
    end
    botmargin && print("\n")
end
