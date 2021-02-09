import Adapt

@testcase "execution" begin

############################################################################################

dummy() = return

@testset "@cuda" begin

@testcase "errors" begin
    @test_throws UndefVarError @cuda undefined()
    @test_throws MethodError @cuda dummy(1)
end


@testcase "launch configuration" begin
    @cuda dummy()

    @cuda threads=1 dummy()
    @cuda threads=(1,1) dummy()
    @cuda threads=(1,1,1) dummy()

    @cuda blocks=1 dummy()
    @cuda blocks=(1,1) dummy()
    @cuda blocks=(1,1,1) dummy()
end


@testcase "launch=false" begin
    k = @cuda launch=false dummy()
    k()
    k(; threads=1)

    CUDA.version(k)
    CUDA.memory(k)
    CUDA.registers(k)
    CUDA.maxthreads(k)
end


@testcase "compilation params" begin
    @cuda dummy()

    @not_if_memcheck @test_throws CuError @cuda threads=2 maxthreads=1 dummy()
    @cuda threads=2 dummy()
end


@testcase "inference" begin
    foo() = @cuda dummy()
    @inferred foo()

    # with arguments, we call cudaconvert
    kernel(a) = return
    bar(a) = @cuda kernel(a)
    @inferred bar(CuArray([1]))
end


@testcase "reflection" begin
    CUDA.code_lowered(dummy, Tuple{})
    CUDA.code_typed(dummy, Tuple{})
    CUDA.code_warntype(devnull, dummy, Tuple{})
    CUDA.code_llvm(devnull, dummy, Tuple{})
    CUDA.code_ptx(devnull, dummy, Tuple{})
    @not_if_memcheck CUDA.code_sass(devnull, dummy, Tuple{})

    @device_code_lowered @cuda dummy()
    @device_code_typed @cuda dummy()
    @device_code_warntype io=devnull @cuda dummy()
    @device_code_llvm io=devnull @cuda dummy()
    @device_code_ptx io=devnull @cuda dummy()
    @not_if_memcheck @device_code_sass io=devnull @cuda dummy()

    mktempdir() do dir
        @device_code dir=dir @cuda dummy()
    end

    @test_throws ErrorException @device_code_lowered nothing

    # make sure kernel name aliases are preserved in the generated code
    @test occursin("julia_dummy", sprint(io->(@device_code_llvm io=io optimize=false @cuda dummy())))
    @test occursin("julia_dummy", sprint(io->(@device_code_llvm io=io @cuda dummy())))
    @test occursin("julia_dummy", sprint(io->(@device_code_ptx io=io @cuda dummy())))
    @not_if_memcheck @test occursin("julia_dummy", sprint(io->(@device_code_sass io=io @cuda dummy())))

    # make sure invalid kernels can be partially reflected upon
    let
        invalid_kernel() = throw()
        @test_throws CUDA.KernelError @cuda invalid_kernel()
        @test_throws CUDA.KernelError @grab_output @device_code_warntype @cuda invalid_kernel()
        out, err = @grab_output begin
            try
                @device_code_warntype @cuda invalid_kernel()
            catch
            end
        end
        @test occursin("Body::Union{}", err)
    end

    let
        range_kernel() = (0.0:0.1:100.0; nothing)

        @test_throws CUDA.InvalidIRError @cuda range_kernel()
    end

    # set name of kernel
    @test occursin("julia_mykernel", sprint(io->(@device_code_llvm io=io begin
        k = cufunction(dummy, name="mykernel")
        k()
    end)))
end


@testcase "shared memory" begin
    @cuda shmem=1 dummy()
end


@testcase "streams" begin
    s = CuStream()
    @cuda stream=s dummy()
end


@testcase "external kernels" begin
    outer = @in_module Expr(:module, true, :Inner, quote end)
    # NOTE: `quote module end` doesn't work
    @eval outer.Inner begin
        export external_dummy
        external_dummy() = return
    end
    @cuda outer.Inner.external_dummy()

    @eval outer begin
        using .Inner
        call_external_dummy() = @cuda external_dummy()
    end
    Base.invokelatest(outer.call_external_dummy)

    @in_module quote
        dummy() = return
        wrapper() = @cuda dummy()

        wrapper()
    end
end


@testcase "calling device function" begin
    @noinline child(i) = sink(i)
    function parent()
        child(1)
        return
    end

    @cuda parent()
end


@testcase "varargs" begin
    function kernel(args...)
        @cuprint(args[2])
        return
    end

    _, out = @grab_output begin
        @cuda kernel(1, 2, 3)
    end
    @test out == "2"
end

end


############################################################################################

@testset "argument passing" begin

dims = (16, 16)

@testcase "manually allocated" begin
    function kernel(input, output)
        i = (blockIdx().x-1) * blockDim().x + threadIdx().x

        val = input[i]
        output[i] = val

        return
    end

    input = round.(rand(Float32, dims) * 100)
    output = similar(input)

    input_dev = CuArray(input)
    output_dev = CuArray(output)

    @cuda threads=length(input) kernel(input_dev, output_dev)
    @test input ≈ Array(output_dev)
end


@testcase "scalar through single-value array" begin
    function kernel(a, x)
        i = (blockIdx().x-1) * blockDim().x + threadIdx().x
        max = gridDim().x * blockDim().x
        if i == max
            _val = a[i]
            x[] = _val
        end
        return
    end

    arr = round.(rand(Float32, dims) * 100)
    val = [0f0]

    arr_dev = CuArray(arr)
    val_dev = CuArray(val)

    @cuda threads=length(arr) kernel(arr_dev, val_dev)
    synchronize_all()
    @test arr[dims...] ≈ Array(val_dev)[1]
end


@testcase "scalar through single-value array, using device function" begin
    @noinline child(a, i) = a[i]
    function parent(a, x)
        i = (blockIdx().x-1) * blockDim().x + threadIdx().x
        max = gridDim().x * blockDim().x
        if i == max
            _val = child(a, i)
            x[] = _val
        end
        return
    end

    arr = round.(rand(Float32, dims) * 100)
    val = [0f0]

    arr_dev = CuArray(arr)
    val_dev = CuArray(val)

    @cuda threads=length(arr) parent(arr_dev, val_dev)
    @test arr[dims...] ≈ Array(val_dev)[1]
end


@testcase "tuples" begin
    # issue #7: tuples not passed by pointer

    function kernel(keeps, out)
        if keeps[1]
            out[] = 1
        else
            out[] = 2
        end
        return
    end

    keeps = (true,)
    d_out = CuArray(zeros(Int))

    @cuda kernel(keeps, d_out)
    @test Array(d_out)[] == 1
end


@testcase "ghost function parameters" begin
    # bug: ghost type function parameters are elided by the compiler
    @in_module quote
        struct ExecGhost end

        len = 60
        a = rand(Float32, len)
        b = rand(Float32, len)
        c = similar(a)

        d_a = CuArray(a)
        d_b = CuArray(b)
        d_c = CuArray(c)

        function kernel(ghost, a, b, c)
            i = (blockIdx().x-1) * blockDim().x + threadIdx().x
            c[i] = a[i] + b[i]
            return
        end
        @cuda threads=len kernel(ExecGhost(), d_a, d_b, d_c)
        @test a+b == Array(d_c)


        # bug: ghost type function parameters confused aggregate type rewriting

        function kernel(ghost, out, aggregate)
            i = (blockIdx().x-1) * blockDim().x + threadIdx().x
            out[i] = aggregate[1]
            return
        end
        @cuda threads=len kernel(ExecGhost(), d_c, (42,))

        @test all(val->val==42, Array(d_c))
    end
end


@testcase "immutables" begin
    # issue #15: immutables not passed by pointer

    function kernel(ptr, b)
        ptr[] = imag(b)
        return
    end

    arr = CuArray(zeros(Float32))
    x = ComplexF32(2,2)

    @cuda kernel(arr, x)
    @test Array(arr)[] == imag(x)
end

@testcase "automatic recompilation" begin
    @in_module quote
        arr = CuArray(zeros(Int))

        function kernel(ptr)
            ptr[] = 1
            return
        end

        @cuda kernel(arr)
        @test Array(arr)[] == 1

        function kernel(ptr)
            ptr[] = 2
            return
        end

        @cuda kernel(arr)
        @test Array(arr)[] == 2
    end
end

@testcase "automatic recompilation (bis)" begin
    @in_module quote
        arr = CuArray(zeros(Int))

        doit(ptr) = ptr[] = 1

        function kernel(ptr)
            doit(ptr)
            return
        end

        @cuda kernel(arr)
        @test Array(arr)[] == 1

        doit(ptr) = ptr[] = 2

        @cuda kernel(arr)
        @test Array(arr)[] == 2
    end
end

@testcase "automatic recompilation (tris)" begin
    arr = CuArray(zeros(Int))

    mod = @in_module quote
        function kernel(ptr)
            ptr[] = 1
            return
        end
    end

    @cuda mod.kernel(arr)
    @test Array(arr)[] == 1

    @eval mod begin
        function kernel(ptr)
            ptr[] = 2
            return
        end
    end

    @cuda mod.kernel(arr)
    @test_broken Array(arr)[] == 2
    # JuliaGPU/GPUArrays.jl#146: this doesn't work because we don't respect world ages
end


@testcase "non-isbits arguments" begin
    function kernel1(T, i)
        sink(i)
        return
    end
    @cuda kernel1(Int, 1)

    function kernel2(T, i)
        sink(unsafe_trunc(T,i))
        return
    end
    @cuda kernel2(Int, 1.)
end


@testcase "splatting" begin
    function kernel(out, a, b)
        out[] = a+b
        return
    end

    out = [0]
    out_dev = CuArray(out)

    @cuda kernel(out_dev, 1, 2)
    @test Array(out_dev)[1] == 3

    all_splat = (out_dev, 3, 4)
    @cuda kernel(all_splat...)
    @test Array(out_dev)[1] == 7

    partial_splat = (5, 6)
    @cuda kernel(out_dev, partial_splat...)
    @test Array(out_dev)[1] == 11
end

@testcase "object invoke" begin
    # this mimics what is generated by closure conversion
    @in_module quote
        struct KernelObject{T} <: Function
            val::T
        end
        function (self::KernelObject)(a)
            a[] = self.val
            return
        end

        function outer(a, val)
        inner = KernelObject(val)
        @cuda inner(a)
        end

        a = [1.]
        a_dev = CuArray(a)

        outer(a_dev, 2.)

        @test Array(a_dev) ≈ [2.]
    end
end

@testcase "closures" begin
    function outer(a_dev, val)
       function inner(a)
            # captures `val`
            a[] = val
            return
       end
       @cuda inner(a_dev)
    end

    a = [1.]
    a_dev = CuArray(a)

    outer(a_dev, 2.)

    @test Array(a_dev) ≈ [2.]
end

@testcase "closure as arguments" begin
    function kernel(closure)
        closure()
        return
    end
    function outer(a_dev, val)
        f() = a_dev[] = val
        @cuda kernel(f)
    end

    a = [1.]
    a_dev = CuArray(a)

    outer(a_dev, 2.)

    @test Array(a_dev) ≈ [2.]
end

@testcase "conversions" begin
    @in_module quote
        struct Host   end
        struct Device end

        CUDA.Adapt.adapt_storage(::CUDA.Adaptor, a::Host) = Device()

        Base.convert(::Type{Int}, ::Host)   = 1
        Base.convert(::Type{Int}, ::Device) = 2

        out = [0]

        # convert arguments
        out_dev = CuArray(out)
        let arg = Host()
            @test Array(out_dev) ≈ [0]
            function kernel(arg, out)
                out[] = convert(Int, arg)
                return
            end
            @cuda kernel(arg, out_dev)
            @test Array(out_dev) ≈ [2]
        end

        # convert captured variables
        out_dev = CuArray(out)
        let arg = Host()
            @test Array(out_dev) ≈ [0]
            function kernel(out)
                out[] = convert(Int, arg)
                return
            end
            @cuda kernel(out_dev)
            @test Array(out_dev) ≈ [2]
        end

        # convert tuples
        out_dev = CuArray(out)
        let arg = (Host(),)
            @test Array(out_dev) ≈ [0]
            function kernel(arg, out)
                out[] = convert(Int, arg[1])
                return
            end
            @cuda kernel(arg, out_dev)
            @test Array(out_dev) ≈ [2]
        end

        # convert named tuples
        out_dev = CuArray(out)
        let arg = (a=Host(),)
            @test Array(out_dev) ≈ [0]
            function kernel(arg, out)
                out[] = convert(Int, arg.a)
                return
            end
            @cuda kernel(arg, out_dev)
            @test Array(out_dev) ≈ [2]
        end

        # don't convert structs
        out_dev = CuArray(out)
        struct Nested
            a::Host
        end
        let arg = Nested(Host())
            @test Array(out_dev) ≈ [0]
            function kernel(arg, out)
                out[] = convert(Int, arg.a)
                return
            end
            @cuda kernel(arg, out_dev)
            @test Array(out_dev) ≈ [1]
        end
    end
end

@testcase "argument count" begin
    val = [0]
    val_dev = CuArray(val)
    for i in (1, 10, 20, 34)
        variables = ('a':'z'..., 'A':'Z'...)
        params = [Symbol(variables[j]) for j in 1:i]
        # generate a kernel
        body = quote
            function kernel(arr, $(params...))
                arr[] = $(Expr(:call, :+, params...))
                return
            end
        end
        eval(body)
        args = [j for j in 1:i]
        call = Expr(:call, :kernel, val_dev, args...)
        cudacall = :(@cuda $call)
        eval(cudacall)
        @test Array(val_dev)[1] == sum(args)
    end
end

@testcase "keyword arguments" begin
    @in_module quote
        @eval inner_kwargf(foobar;foo=1, bar=2) = nothing

        @cuda (()->inner_kwargf(42;foo=1,bar=2))()

        @cuda (()->inner_kwargf(42))()

        @cuda (()->inner_kwargf(42;foo=1))()

        @cuda (()->inner_kwargf(42;bar=2))()

        @cuda (()->inner_kwargf(42;bar=2,foo=1))()
    end
end

@testcase "captured values" begin
    function f(capture::T) where {T}
        function kernel(ptr)
            ptr[] = capture
            return
        end

        arr = CuArray(zeros(T))
        @cuda kernel(arr)

        return Array(arr)[1]
    end

    @test f(1) == 1
    @test f(2) == 2
end

end

############################################################################################

@testset "shmem divergence bug" begin

@testcase "trap" begin
    function trap()
        ccall("llvm.trap", llvmcall, Cvoid, ())
    end

    function kernel(input::Int32, output::Core.LLVMPtr{Int32}, yes::Bool=true)
        i = threadIdx().x

        temp = @cuStaticSharedMem(Cint, 1)
        if i == 1
            yes || trap()
            temp[1] = input
        end
        sync_threads()

        yes || trap()
        unsafe_store!(output, temp[1], i)

        return nothing
    end

    input = rand(Cint(1):Cint(100))
    N = 2

    let output = CuArray(zeros(Cint, N))
        # defaulting to `true` embeds this info in the PTX module,
        # allowing `ptxas` to emit validly-structured code.
        ptr = pointer(output)
        @cuda threads=N kernel(input, ptr)
        @test Array(output) == fill(input, N)
    end

    let output = CuArray(zeros(Cint, N))
        ptr = pointer(output)
        @cuda threads=N kernel(input, ptr, true)
        @test Array(output) == fill(input, N)
    end
end

@testcase "unreachable" begin
    function unreachable()
        @cuprintln("go home ptxas you're drunk")
        Base.llvmcall("unreachable", Cvoid, Tuple{})
    end

    function kernel(input::Int32, output::Core.LLVMPtr{Int32}, yes::Bool=true)
        i = threadIdx().x

        temp = @cuStaticSharedMem(Cint, 1)
        if i == 1
            yes || unreachable()
            temp[1] = input
        end
        sync_threads()

        yes || unreachable()
        unsafe_store!(output, temp[1], i)

        return nothing
    end

    input = rand(Cint(1):Cint(100))
    N = 2

    let output = CuArray(zeros(Cint, N))
        # defaulting to `true` embeds this info in the PTX module,
        # allowing `ptxas` to emit validly-structured code.
        ptr = pointer(output)
        @cuda threads=N kernel(input, ptr)
        @test Array(output) == fill(input, N)
    end

    let output = CuArray(zeros(Cint, N))
        ptr = pointer(output)
        @cuda threads=N kernel(input, ptr, true)
        @test Array(output) == fill(input, N)
    end
end

@testcase "mapreduce (full)" begin
    function mapreduce_gpu(f::Function, op::Function, A::CuArray{T, N}; dims = :, init...) where {T, N}
        OT = Float32
        v0 =  0.0f0

        threads = 256
        out = CuArray{OT}(undef, (1,))
        @cuda threads=threads reduce_kernel(f, op, v0, A, Val{threads}(), out)
        Array(out)[1]
    end

    function reduce_kernel(f, op, v0::T, A, ::Val{LMEM}, result) where {T, LMEM}
        tmp_local = @cuStaticSharedMem(T, LMEM)
        global_index = threadIdx().x
        acc = v0

        # Loop sequentially over chunks of input vector
        while global_index <= length(A)
            element = f(A[global_index])
            acc = op(acc, element)
            global_index += blockDim().x
        end

        # Perform parallel reduction
        local_index = threadIdx().x - 1
        @inbounds tmp_local[local_index + 1] = acc
        sync_threads()

        offset = blockDim().x ÷ 2
        while offset > 0
            @inbounds if local_index < offset
                other = tmp_local[local_index + offset + 1]
                mine = tmp_local[local_index + 1]
                tmp_local[local_index + 1] = op(mine, other)
            end
            sync_threads()
            offset = offset ÷ 2
        end

        if local_index == 0
            result[blockIdx().x] = @inbounds tmp_local[1]
        end

        return
    end

    A = rand(Float32, 1000)
    dA = CuArray(A)

    @test mapreduce(identity, +, A) ≈ mapreduce_gpu(identity, +, dA)
end

@testcase "mapreduce (full, complex)" begin
    function mapreduce_gpu(f::Function, op::Function, A::CuArray{T, N}; dims = :, init...) where {T, N}
        OT = Complex{Float32}
        v0 =  0.0f0+0im

        threads = 256
        out = CuArray{OT}(undef, (1,))
        @cuda threads=threads reduce_kernel(f, op, v0, A, Val{threads}(), out)
        Array(out)[1]
    end

    function reduce_kernel(f, op, v0::T, A, ::Val{LMEM}, result) where {T, LMEM}
        tmp_local = @cuStaticSharedMem(T, LMEM)
        global_index = threadIdx().x
        acc = v0

        # Loop sequentially over chunks of input vector
        while global_index <= length(A)
            element = f(A[global_index])
            acc = op(acc, element)
            global_index += blockDim().x
        end

        # Perform parallel reduction
        local_index = threadIdx().x - 1
        @inbounds tmp_local[local_index + 1] = acc
        sync_threads()

        offset = blockDim().x ÷ 2
        while offset > 0
            @inbounds if local_index < offset
                other = tmp_local[local_index + offset + 1]
                mine = tmp_local[local_index + 1]
                tmp_local[local_index + 1] = op(mine, other)
            end
            sync_threads()
            offset = offset ÷ 2
        end

        if local_index == 0
            result[blockIdx().x] = @inbounds tmp_local[1]
        end

        return
    end

    A = rand(Complex{Float32}, 1000)
    dA = CuArray(A)

    @test mapreduce(identity, +, A) ≈ mapreduce_gpu(identity, +, dA)
end

@testcase "mapreduce (reduced)" begin
    function mapreduce_gpu(f::Function, op::Function, A::CuArray{T, N}) where {T, N}
        OT = Int
        v0 = 0

        out = CuArray{OT}(undef, (1,))
        @cuda threads=64 reduce_kernel(f, op, v0, A, out)
        Array(out)[1]
    end

    function reduce_kernel(f, op, v0::T, A, result) where {T}
        tmp_local = @cuStaticSharedMem(T, 64)
        acc = v0

        # Loop sequentially over chunks of input vector
        i = threadIdx().x
        while i <= length(A)
            element = f(A[i])
            acc = op(acc, element)
            i += blockDim().x
        end

        # Perform parallel reduction
        @inbounds tmp_local[threadIdx().x] = acc
        sync_threads()

        offset = blockDim().x ÷ 2
        while offset > 0
            @inbounds if threadIdx().x <= offset
                other = tmp_local[(threadIdx().x - 1) + offset + 1]
                mine = tmp_local[threadIdx().x]
                tmp_local[threadIdx().x] = op(mine, other)
            end
            sync_threads()
            offset = offset ÷ 2
        end

        if threadIdx().x == 1
            result[blockIdx().x] = @inbounds tmp_local[1]
        end

        return
    end

    A = rand(1:10, 100)
    dA = CuArray(A)

    @test mapreduce(identity, +, A) ≈ mapreduce_gpu(identity, +, dA)
end

end

############################################################################################

@testset "dynamic parallelism" begin

@testcase "basic usage" begin
    @in_module quote
        function hello()
            @cuprint("Hello, ")
            @cuda dynamic=true world()
            return
        end

        function world()
            @cuprint("World!")
            return
        end

        _, out = @grab_output begin
            @cuda hello()
        end
        @test out == "Hello, World!"
    end
end

@testcase "anonymous functions" begin
    function hello()
        @cuprint("Hello, ")
        world = () -> (@cuprint("World!"); nothing)
        @cuda dynamic=true world()
        return
    end

    _, out = @grab_output begin
        @cuda hello()
    end
    @test out == "Hello, World!"
end

if VERSION >= v"1.1" # behavior of captured variables (box or not) has improved over time
@testcase "closures" begin
    function hello()
        x = 1
        @cuprint("Hello, ")
        world = () -> (@cuprint("World $(x)!"); nothing)
        @cuda dynamic=true world()
        return
    end

    _, out = @grab_output begin
        @cuda hello()
    end
    @test out == "Hello, World 1!"
end
end

@testcase "argument passing" begin
    ## padding

    function kernel(a, b, c)
        @cuprint("$a $b $c")
        return
    end

    for args in ((Int16(1), Int32(2), Int64(3)),    # padding
                 (Int32(1), Int32(2), Int32(3)),    # no padding, equal size
                 (Int64(1), Int32(2), Int16(3)),    # no padding, inequal size
                 (Int16(1), Int64(2), Int32(3)))    # mixed
        _, out = @grab_output begin
            @cuda kernel(args...)
        end
        @test out == "1 2 3"
    end

    ## conversion

    function kernel(a)
        increment(a) = (a[1] += 1; nothing)

        a[1] = 1
        increment(a)
        @cuda dynamic=true increment(a)

        return
    end

    dA = CuArray{Int}(undef, (1,))
    @cuda kernel(dA)
    A = Array(dA)
    @test A == [3]
end

@testcase "self-recursion" begin
    @in_module quote
        function kernel(x::Bool)
            if x
                @cuprint("recurse ")
                @cuda dynamic=true kernel(false)
            else
                @cuprint("stop")
            end
            return
        end

        _, out = @grab_output begin
            @cuda kernel(true)
        end
        @test out == "recurse stop"
    end
end

@testcase "deep recursion" begin
    @in_module quote
        function kernel_a(x::Bool)
            @cuprint("a ")
            @cuda dynamic=true kernel_b(x)
            return
        end

        function kernel_b(x::Bool)
            @cuprint("b ")
            @cuda dynamic=true kernel_c(x)
            return
        end

        function kernel_c(x::Bool)
            @cuprint("c ")
            if x
                @cuprint("recurse ")
                @cuda dynamic=true kernel_a(false)
            else
                @cuprint("stop")
            end
            return
        end

        _, out = @grab_output begin
            @cuda kernel_a(true)
        end
        @test out == "a b c recurse a b c stop"
    end
end

@testcase "streams" begin
    @in_module quote
        function hello()
            @cuprint("Hello, ")
            s = CuDeviceStream()
            @cuda dynamic=true stream=s world()
            CUDA.unsafe_destroy!(s)
            return
        end

        function world()
            @cuprint("World!")
            return
        end

        _, out = @grab_output begin
            @cuda hello()
        end
        @test out == "Hello, World!"
    end
end

@testcase "parameter alignment" begin
    # foo is unused, but determines placement of bar
    function child(x, foo, bar)
        x[] = sum(bar)
        return
    end
    function parent(x, foo, bar)
        @cuda dynamic=true child(x, foo, bar)
        return
    end

    for (Foo, Bar) in [(Tuple{},NTuple{8,Int}), # JuliaGPU/CUDA.jl#263
                        (Tuple{Int32},Tuple{Int16}),
                        (Tuple{Int16},Tuple{Int32,Int8,Int16,Int64,Int16,Int16})]
        foo = (Any[T(i) for (i,T) in enumerate(Foo.parameters)]...,)
        bar = (Any[T(i) for (i,T) in enumerate(Bar.parameters)]...,)

        x, y = CUDA.zeros(Int, 1), CUDA.zeros(Int, 1)
        @cuda child(x, foo, bar)
        @cuda parent(y, foo, bar)
        @test sum(bar) == Array(x)[] == Array(y)[]
    end
end

@testcase "many arguments" begin
    # JuliaGPU/CUDA.jl#401
    function dp_5arg_kernel(v1, v2, v3, v4, v5)
        return nothing
    end

    function dp_6arg_kernel(v1, v2, v3, v4, v5, v6)
        return nothing
    end

    function main_5arg_kernel()
        @cuda threads=1 dynamic=true dp_5arg_kernel(1, 1, 1, 1, 1)
        return nothing
    end

    function main_6arg_kernel()
        @cuda threads=1 dynamic=true dp_6arg_kernel(1, 1, 1, 1, 1, 1)
        return nothing
    end

    @cuda threads=1 dp_5arg_kernel(1, 1, 1, 1, 1)
    @cuda threads=1 dp_6arg_kernel(1, 1, 1, 1, 1, 1)
    @cuda threads=1 main_5arg_kernel()
    @cuda threads=1 main_6arg_kernel()
end

end

############################################################################################

@run_if capability(device()) >= v"6.0" && attribute(device(), CUDA.DEVICE_ATTRIBUTE_COOPERATIVE_LAUNCH) == 1 begin

@testcase "cooperative groups" begin
    function kernel_vadd(a, b, c)
        i = (blockIdx().x-1) * blockDim().x + threadIdx().x
        grid_handle = this_grid()
        c[i] = a[i] + b[i]
        sync_grid(grid_handle)
        c[i] = c[1]
        return nothing
    end

    # cooperative kernels are additionally limited in the number of blocks that can be launched
    maxBlocks = attribute(device(), CUDA.DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT)
    kernel = cufunction(kernel_vadd, NTuple{3, CuDeviceArray{Float32,2,AS.Global}})
    maxThreads = CUDA.maxthreads(kernel)

    a = rand(Float32, maxBlocks, maxThreads)
    b = rand(Float32, size(a)) * 100
    c = similar(a)
    d_a = CuArray(a)
    d_b = CuArray(b)
    d_c = CuArray(c)  # output array

    @cuda cooperative=true threads=maxThreads blocks=maxBlocks kernel_vadd(d_a, d_b, d_c)

    c = Array(d_c)
    @test all(c[1] .== c)
end

end

############################################################################################

end
