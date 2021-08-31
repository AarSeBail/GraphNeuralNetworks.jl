@testset "cuda/featured graph" begin
    s = [1,1,2,3,4,5,5,5]
    t = [2,5,3,2,1,4,3,1]
    s, t = [s; t], [t; s]  #symmetrize
    fg = FeaturedGraph(s, t, graph_type=GRAPH_T) 
    fg_gpu = fg |> gpu

    @testset "functor" begin
        s_cpu, t_cpu = edge_index(fg)
        s_gpu, t_gpu = edge_index(fg_gpu)
        @test s_gpu isa CuVector{Int}
        @test Array(s_gpu) == s_cpu
        @test t_gpu isa CuVector{Int}
        @test Array(t_gpu) == t_cpu
    end

    @testset "adjacency_matrix" begin
        function test_adj()
            mat = adjacency_matrix(fg)
            mat_gpu = adjacency_matrix(fg_gpu)
            @test mat_gpu isa CuMatrix{Int}
            true
        end

        if GRAPH_T == :coo
            # See https://github.com/JuliaGPU/CUDA.jl/pull/1093
            @test_broken test_adj()
        else
            test_adj()
        end
    end

    @testset "normalized_laplacian" begin
        function test_normlapl()
            mat = normalized_laplacian(fg)
            mat_gpu = normalized_laplacian(fg_gpu)
            @test mat_gpu isa CuMatrix{Float32}
            true
        end
        if GRAPH_T == :coo
            @test_broken test_normlapl()
        else
            test_normlapl()
        end
    end

    @testset "scaled_laplacian" begin
        @test_broken begin
            mat = scaled_laplacian(fg)
            mat_gpu = scaled_laplacian(fg_gpu)
            @test mat_gpu isa CuMatrix{Float32}
            true
        end
    end
end