@doc raw"""
    GCNConv(in => out, σ=identity; bias=true, init=glorot_uniform, add_self_loops=true)

Graph convolutional layer from paper [Semi-supervised Classification with Graph Convolutional Networks](https://arxiv.org/abs/1609.02907).

Performs the operation
```math
\mathbf{x}'_i = \sum_{j\in N(i)} \frac{1}{c_{ij}} W \mathbf{x}_j
```
where ``c_{ij} = \sqrt{|N(i)||N(j)|}``.

The input to the layer is a node feature array `X` 
of size `(num_features, num_nodes)`.

# Arguments

- `in`: Number of input features.
- `out`: Number of output features.
- `σ`: Activation function.
- `bias`: Add learnable bias.
- `init`: Weights' initializer.
- `add_self_loops`: Add self loops to the graph before performing the convolution.
"""
struct GCNConv{A<:AbstractMatrix, B, F} <: GNNLayer
    weight::A
    bias::B
    σ::F
    add_self_loops::Bool
end

@functor GCNConv

function GCNConv(ch::Pair{Int,Int}, σ=identity;
                 init=glorot_uniform, bias::Bool=true,
                 add_self_loops=true)
    in, out = ch
    W = init(out, in)
    b = bias ? Flux.create_bias(W, true, out) : false
    GCNConv(W, b, σ, add_self_loops)
end

## Matrix operations are more performant, 
## but cannot compute the normalized adjacency of sparse cuda matrices yet,
## therefore fallback to message passing framework on gpu for the time being
 
function (l::GCNConv)(g::GNNGraph, x::AbstractMatrix{T}) where T
    Ã = normalized_adjacency(g, T; dir=:out, l.add_self_loops)
    l.σ.(l.weight * x * Ã .+ l.bias)
end

compute_message(l::GCNConv, xi, xj, eij) = xj
update_node(l::GCNConv, m, x) = m

function (l::GCNConv)(g::GNNGraph, x::CuMatrix{T}) where T
    if l.add_self_loops
        g = add_self_loops(g)
    end
    c = 1 ./ sqrt.(degree(g, T, dir=:in))
    x = x .* c'
    x, _ = propagate(l, g, +, x)
    x = x .* c'
    return l.σ.(l.weight * x .+ l.bias)
end

function Base.show(io::IO, l::GCNConv)
    out, in = size(l.weight)
    print(io, "GCNConv($in => $out")
    l.σ == identity || print(io, ", ", l.σ)
    print(io, ")")
end


@doc raw"""
    ChebConv(in => out, k; bias=true, init=glorot_uniform)

Chebyshev spectral graph convolutional layer from
paper [Convolutional Neural Networks on Graphs with Fast Localized Spectral Filtering](https://arxiv.org/abs/1606.09375).

Implements

```math
X' = \sum^{K-1}_{k=0}  W^{(k)} Z^{(k)}
```

where ``Z^{(k)}`` is the ``k``-th term of Chebyshev polynomials, and can be calculated by the following recursive form:

```math
Z^{(0)} = X \\
Z^{(1)} = \hat{L} X \\
Z^{(k)} = 2 \hat{L} Z^{(k-1)} - Z^{(k-2)}
```

with ``\hat{L}`` the [`scaled_laplacian`](@ref).

# Arguments

- `in`: The dimension of input features.
- `out`: The dimension of output features.
- `k`: The order of Chebyshev polynomial.
- `bias`: Add learnable bias.
- `init`: Weights' initializer.
"""
struct ChebConv{A<:AbstractArray{<:Number,3}, B} <: GNNLayer
    weight::A
    bias::B
    k::Int
end

function ChebConv(ch::Pair{Int,Int}, k::Int;
                  init=glorot_uniform, bias::Bool=true)
    in, out = ch
    W = init(out, in, k)
    b = bias ? Flux.create_bias(W, true, out) : false
    ChebConv(W, b, k)
end

@functor ChebConv

function (c::ChebConv)(g::GNNGraph, X::AbstractMatrix{T}) where T
    check_num_nodes(g, X)
    @assert size(X, 1) == size(c.weight, 2) "Input feature size must match input channel size."
    
    L̃ = scaled_laplacian(g, eltype(X))    

    Z_prev = X
    Z = X * L̃
    Y = view(c.weight,:,:,1) * Z_prev
    Y += view(c.weight,:,:,2) * Z
    for k = 3:c.k
        Z, Z_prev = 2*Z*L̃ - Z_prev, Z
        Y += view(c.weight,:,:,k) * Z
    end
    return Y .+ c.bias
end

function Base.show(io::IO, l::ChebConv)
    out, in, k = size(l.weight)
    print(io, "ChebConv(", in, " => ", out)
    print(io, ", k=", k)
    print(io, ")")
end


@doc raw"""
    GraphConv(in => out, σ=identity; aggr=+, bias=true, init=glorot_uniform)

Graph convolution layer from Reference: [Weisfeiler and Leman Go Neural: Higher-order Graph Neural Networks](https://arxiv.org/abs/1810.02244).

Performs:
```math
\mathbf{x}_i' = W_1 \mathbf{x}_i + \square_{j \in \mathcal{N}(i)} W_2 \mathbf{x}_j
```

where the aggregation type is selected by `aggr`.

# Arguments

- `in`: The dimension of input features.
- `out`: The dimension of output features.
- `σ`: Activation function.
- `aggr`: Aggregation operator for the incoming messages (e.g. `+`, `*`, `max`, `min`, and `mean`).
- `bias`: Add learnable bias.
- `init`: Weights' initializer.
"""
struct GraphConv{A<:AbstractMatrix, B} <: GNNLayer
    weight1::A
    weight2::A
    bias::B
    σ
    aggr
end

@functor GraphConv

function GraphConv(ch::Pair{Int,Int}, σ=identity; aggr=+,
                   init=glorot_uniform, bias::Bool=true)
    in, out = ch
    W1 = init(out, in)
    W2 = init(out, in)
    b = bias ? Flux.create_bias(W1, true, out) : false
    GraphConv(W1, W2, b, σ, aggr)
end

compute_message(l::GraphConv, x_i, x_j, e_ij) =  x_j
update_node(l::GraphConv, m, x) = l.σ.(l.weight1 * x .+ l.weight2 * m .+ l.bias)

function (l::GraphConv)(g::GNNGraph, x::AbstractMatrix)
    check_num_nodes(g, x)
    x, _ = propagate(l, g, l.aggr, x)
    x
end

function Base.show(io::IO, l::GraphConv)
    in_channel = size(l.weight1, ndims(l.weight1))
    out_channel = size(l.weight1, ndims(l.weight1)-1)
    print(io, "GraphConv(", in_channel, " => ", out_channel)
    l.σ == identity || print(io, ", ", l.σ)
    print(io, ", aggr=", l.aggr)
    print(io, ")")
end


@doc raw"""
    GATConv(in => out, σ=identity;
            heads=1,
            concat=true,
            init=glorot_uniform    
            bias=true, 
            negative_slope=0.2f0)

Graph attentional layer from the paper [Graph Attention Networks](https://arxiv.org/abs/1710.10903).

Implements the operation
```math
\mathbf{x}_i' = \sum_{j \in N(i)} \alpha_{ij} W \mathbf{x}_j
```
where the attention coefficients ``\alpha_{ij}`` are given by
```math
\alpha_{ij} = \frac{1}{z_i} \exp(LeakyReLU(\mathbf{a}^T [W \mathbf{x}_i \,\|\, W \mathbf{x}_j]))
```
with ``z_i`` a normalization factor.

# Arguments

- `in`: The dimension of input features.
- `out`: The dimension of output features.
- `bias`: Learn the additive bias if true.
- `heads`: Number attention heads.
- `concat`: Concatenate layer output or not. If not, layer output is averaged over the heads.
- `negative_slope`: The parameter of LeakyReLU.
"""
struct GATConv{T, A<:AbstractMatrix, B} <: GNNLayer
    weight::A
    bias::B
    a::A
    σ
    negative_slope::T
    channel::Pair{Int, Int}
    heads::Int
    concat::Bool
end

@functor GATConv
Flux.trainable(l::GATConv) = (l.weight, l.bias, l.a)

function GATConv(ch::Pair{Int,Int}, σ=identity;
                 heads::Int=1, concat::Bool=true, negative_slope=0.2,
                 init=glorot_uniform, bias::Bool=true)
    in, out = ch             
    W = init(out*heads, in)
    if concat 
        b = bias ? Flux.create_bias(W, true, out*heads) : false
    else
        b = bias ? Flux.create_bias(W, true, out) : false
    end
    a = init(2*out, heads)
    negative_slope = convert(eltype(W), negative_slope)
    GATConv(W, b, a, σ, negative_slope, ch, heads, concat)
end

function compute_message(l::GATConv, Wxi, Wxj)
    aWW = sum(l.a .* vcat(Wxi, Wxj), dims=1)   # 1 × nheads × nedges
    α = exp.(leakyrelu.(aWW, l.negative_slope))       
    return (α = α, m = α .* Wxj)
end

update_node(l::GATConv, d̄, x) = d̄.m ./ d̄.α

function (l::GATConv)(g::GNNGraph, x::AbstractMatrix)
    check_num_nodes(g, x)
    g = add_self_loops(g)
    chin, chout = l.channel
    heads = l.heads

    Wx = l.weight * x
    Wx = reshape(Wx, chout, heads, :)                   # chout × nheads × nnodes
    
    x, _ = propagate(l, g, +, Wx)                 ## chout × nheads × nnodes

    if !l.concat
        x = mean(x, dims=2)
    end
    x = reshape(x, :, size(x, 3))  # return a matrix
    x = l.σ.(x .+ l.bias)                                      

    return x  
end


function Base.show(io::IO, l::GATConv)
    out_channel, in_channel = size(l.weight)
    print(io, "GATConv(", in_channel, "=>", out_channel ÷ l.heads)
    print(io, ", LeakyReLU(λ=", l.negative_slope)
    print(io, "))")
end


@doc raw"""
    GatedGraphConv(out, num_layers; aggr=+, init=glorot_uniform)

Gated graph convolution layer from [Gated Graph Sequence Neural Networks](https://arxiv.org/abs/1511.05493).

Implements the recursion
```math
\mathbf{h}^{(0)}_i = \mathbf{x}_i || \mathbf{0} \\
\mathbf{h}^{(l)}_i = GRU(\mathbf{h}^{(l-1)}_i, \square_{j \in N(i)} W \mathbf{h}^{(l-1)}_j)
```

 where ``\mathbf{h}^{(l)}_i`` denotes the ``l``-th hidden variables passing through GRU. The dimension of input ``\mathbf{x}_i`` needs to be less or equal to `out`.

# Arguments

- `out`: The dimension of output features.
- `num_layers`: The number of gated recurrent unit.
- `aggr`: Aggregation operator for the incoming messages (e.g. `+`, `*`, `max`, `min`, and `mean`).
- `init`: Weight initialization function.
"""
struct GatedGraphConv{A<:AbstractArray{<:Number,3}, R} <: GNNLayer
    weight::A
    gru::R
    out_ch::Int
    num_layers::Int
    aggr
end

@functor GatedGraphConv


function GatedGraphConv(out_ch::Int, num_layers::Int;
                        aggr=+, init=glorot_uniform)
    w = init(out_ch, out_ch, num_layers)
    gru = GRUCell(out_ch, out_ch)
    GatedGraphConv(w, gru, out_ch, num_layers, aggr)
end


compute_message(l::GatedGraphConv, x_i, x_j, e_ij) = x_j
update_node(l::GatedGraphConv, m, x) = m

# remove after https://github.com/JuliaDiff/ChainRules.jl/pull/521
@non_differentiable fill!(x...)

function (l::GatedGraphConv)(g::GNNGraph, H::AbstractMatrix{S}) where {S<:Real}
    check_num_nodes(g, H)
    m, n = size(H)
    @assert (m <= l.out_ch) "number of input features must less or equals to output features."
    if m < l.out_ch
        Hpad = similar(H, S, l.out_ch - m, n)
        H = vcat(H, fill!(Hpad, 0))
    end
    for i = 1:l.num_layers
        M = view(l.weight, :, :, i) * H
        M, _ = propagate(l, g, l.aggr, M)
        H, _ = l.gru(H, M)
    end
    H
end

function Base.show(io::IO, l::GatedGraphConv)
    print(io, "GatedGraphConv(($(l.out_ch) => $(l.out_ch))^$(l.num_layers)")
    print(io, ", aggr=", l.aggr)
    print(io, ")")
end


@doc raw"""
    EdgeConv(nn; aggr=max)

Edge convolutional layer from paper [Dynamic Graph CNN for Learning on Point Clouds](https://arxiv.org/abs/1801.07829).

Performs the operation
```math
\mathbf{x}_i' = \square_{j \in N(i)} nn(\mathbf{x}_i || \mathbf{x}_j - \mathbf{x}_i)
```

where `nn` generally denotes a learnable function, e.g. a linear layer or a multi-layer perceptron.

# Arguments

- `nn`: A (possibly learnable) function acting on edge features. 
- `aggr`: Aggregation operator for the incoming messages (e.g. `+`, `*`, `max`, `min`, and `mean`).
"""
struct EdgeConv <: GNNLayer
    nn
    aggr
end

@functor EdgeConv

EdgeConv(nn; aggr=max) = EdgeConv(nn, aggr)

compute_message(l::EdgeConv, x_i, x_j, e_ij) = l.nn(vcat(x_i, x_j .- x_i))

update_node(l::EdgeConv, m, x) = m

function (l::EdgeConv)(g::GNNGraph, X::AbstractMatrix)
    check_num_nodes(g, X)
    X, _ = propagate(l, g, l.aggr, X)
    X
end

function Base.show(io::IO, l::EdgeConv)
    print(io, "EdgeConv(", l.nn)
    print(io, ", aggr=", l.aggr)
    print(io, ")")
end


@doc raw"""
    GINConv(f, ϵ; aggr=+)

Graph Isomorphism convolutional layer from paper [How Powerful are Graph Neural Networks?](https://arxiv.org/pdf/1810.00826.pdf)


```math
\mathbf{x}_i' = f_\Theta\left((1 + \epsilon) \mathbf{x}_i + \sum_{j \in N(i)} \mathbf{x}_j \right)
```
where ``f_\Theta`` typically denotes a learnable function, e.g. a linear layer or a multi-layer perceptron.

# Arguments

- `f`: A (possibly learnable) function acting on node features. 
- `ϵ`: Weighting factor.
"""
struct GINConv{R<:Real} <: GNNLayer
    nn
    ϵ::R
    aggr
end

@functor GINConv
Flux.trainable(l::GINConv) = (l.nn,)

GINConv(nn, ϵ; aggr=+) = GINConv(nn, ϵ, aggr)


compute_message(l::GINConv, x_i, x_j, e_ij) = x_j 
update_node(l::GINConv, m, x) = l.nn((1 + ofeltype(x, l.ϵ)) * x + m)

function (l::GINConv)(g::GNNGraph, X::AbstractMatrix)
    check_num_nodes(g, X)
    X, _ = propagate(l, g, l.aggr, X)
    X
end


function Base.show(io::IO, l::GINConv)
    print(io, "GINConv($(l.nn)")
    print(io, ", $(l.ϵ)")
    print(io, ")")
end



@doc raw"""
    NNConv(in => out, f, σ=identity; aggr=+, bias=true, init=glorot_uniform)

The continuous kernel-based convolutional operator from the 
[Neural Message Passing for Quantum Chemistry](https://arxiv.org/abs/1704.01212) paper. 
This convolution is also known as the edge-conditioned convolution from the 
[Dynamic Edge-Conditioned Filters in Convolutional Neural Networks on Graphs](https://arxiv.org/abs/1704.02901) paper.

Performs the operation

```math
\mathbf{x}_i' = W \mathbf{x}_i + \square_{j \in N(i)} f_\Theta(\mathbf{e}_{j\to i})\,\mathbf{x}_j
```

where ``f_\Theta``  denotes a learnable function (e.g. a linear layer or a multi-layer perceptron).
Given an input of batched edge features `e` of size `(num_edge_features, num_edges)`, 
the function `f` will return an batched matrices array whose size is `(out, in, num_edges)`.
For convenience, also functions returning a single `(out*in, num_edges)` matrix are allowed.

# Arguments

- `in`: The dimension of input features.
- `out`: The dimension of output features.
- `f`: A (possibly learnable) function acting on edge features.
- `aggr`: Aggregation operator for the incoming messages (e.g. `+`, `*`, `max`, `min`, and `mean`).
- `σ`: Activation function.
- `bias`: Add learnable bias.
- `init`: Weights' initializer.
"""
struct NNConv <: GNNLayer
    weight
    bias
    nn
    σ
    aggr
end

@functor NNConv

function NNConv(ch::Pair{Int,Int}, nn, σ=identity; aggr=+, bias=true, init=glorot_uniform)
    in, out = ch
    W = init(out, in)
    b = bias ? Flux.create_bias(W, true, out) : false
    return NNConv(W, b, nn, σ, aggr)
end

function compute_message(l::NNConv, x_i, x_j, e_ij) 
    nin, nedges = size(x_i)
    W = reshape(l.nn(e_ij), (:, nin, nedges))
    x_j = reshape(x_j, (nin, 1, nedges)) # needed by batched_mul
    m = NNlib.batched_mul(W, x_j)
    return reshape(m, :, nedges)
end

function update_node(l::NNConv, m, x)
    l.σ.(l.weight*x .+ m .+ l.bias)
end

function (l::NNConv)(g::GNNGraph, x::AbstractMatrix, e)
    check_num_nodes(g, x)
    x, _ = propagate(l, g, l.aggr, x, e)
    return x
end

(l::NNConv)(g::GNNGraph) = GNNGraph(g, ndata=l(g, node_features(g), edge_features(g)))

function Base.show(io::IO, l::NNConv)
    out, in = size(l.weight)
    print(io, "NNConv( $in => $out")
    print(io, ", aggr=", l.aggr)
    print(io, ")")
end


@doc raw"""
    SAGEConv(in => out, σ=identity; aggr=mean, bias=true, init=glorot_uniform)

GraphSAGE convolution layer from paper [Inductive Representation Learning on Large Graphs](https://arxiv.org/pdf/1706.02216.pdf).

Performs:
```math
\mathbf{x}_i' = W [\mathbf{x}_i \,\|\, \square_{j \in \mathcal{N}(i)} \mathbf{x}_j]
```

where the aggregation type is selected by `aggr`.

# Arguments

- `in`: The dimension of input features.
- `out`: The dimension of output features.
- `σ`: Activation function.
- `aggr`: Aggregation operator for the incoming messages (e.g. `+`, `*`, `max`, `min`, and `mean`).
- `bias`: Add learnable bias.
- `init`: Weights' initializer.
"""
struct SAGEConv{A<:AbstractMatrix, B} <: GNNLayer
    weight::A
    bias::B
    σ
    aggr
end

@functor SAGEConv

function SAGEConv(ch::Pair{Int,Int}, σ=identity; aggr=mean,
                   init=glorot_uniform, bias::Bool=true)
    in, out = ch
    W = init(out, 2*in)
    b = bias ? Flux.create_bias(W, true, out) : false
    SAGEConv(W, b, σ, aggr)
end

compute_message(l::SAGEConv, x_i, x_j, e_ij) =  x_j
update_node(l::SAGEConv, m, x) = l.σ.(l.weight * vcat(x, m) .+ l.bias)

function (l::SAGEConv)(g::GNNGraph, x::AbstractMatrix)
    check_num_nodes(g, x)
    x, _ = propagate(l, g, l.aggr, x)
    x
end

function Base.show(io::IO, l::SAGEConv)
    out_channel, in_channel = size(l.weight)
    print(io, "SAGEConv(", in_channel ÷ 2, " => ", out_channel)
    l.σ == identity || print(io, ", ", l.σ)
    print(io, ", aggr=", l.aggr)
    print(io, ")")
end


@doc raw"""
    ResGatedGraphConv(in => out, act=identity; init=glorot_uniform, bias=true)

The residual gated graph convolutional operator from the [Residual Gated Graph ConvNets](https://arxiv.org/abs/1711.07553) paper.

The layer's forward pass is given by

```math
\mathbf{x}_i' = act\big(U\mathbf{x}_i + \sum_{j \in N(i)} \eta_{ij} V \mathbf{x}_j\big),
```
where the edge gates ``\eta_{ij}`` are given by

```math
\eta_{ij} = sigmoid(A\mathbf{x}_i + B\mathbf{x}_j).
```

# Arguments

- `in`: The dimension of input features.
- `out`: The dimension of output features.
- `act`: Activation function.
- `init`: Weight matrices' initializing function. 
- `bias`: Learn an additive bias if true.
"""
struct ResGatedGraphConv <: GNNLayer
    A
    B
    U
    V
    bias
    σ
end

@functor ResGatedGraphConv

function ResGatedGraphConv(ch::Pair{Int,Int}, σ=identity;
                      init=glorot_uniform, bias::Bool=true)
    in, out = ch             
    A = init(out, in)
    B = init(out, in)
    U = init(out, in)
    V = init(out, in)
    b = bias ? Flux.create_bias(A, true, out) : false
    return ResGatedGraphConv(A, B, U, V, b, σ)
end

function compute_message(l::ResGatedGraphConv, di, dj)
    η = sigmoid.(di.Ax .+ dj.Bx)
    return η .* dj.Vx
end

update_node(l::ResGatedGraphConv, m, x) = m

function (l::ResGatedGraphConv)(g::GNNGraph, x::AbstractMatrix)
    check_num_nodes(g, x)

    Ax = l.A * x
    Bx = l.B * x
    Vx = l.V * x
    
    m, _ = propagate(l, g, +, (; Ax, Bx, Vx))

    return l.σ.(l.U*x .+ m .+ l.bias)                                      
end


function Base.show(io::IO, l::ResGatedGraphConv)
    out_channel, in_channel = size(l.A)
    print(io, "ResGatedGraphConv(", in_channel, "=>", out_channel)
    l.σ == identity || print(io, ", ", l.σ)
    print(io, ")")
end
