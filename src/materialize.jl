"""
    JSONBase.materialize(json)
    JSONBase.materialize(json, T)

Materialize a JSON input (string, vector, stream, LazyValue, BinaryValue, etc.) into a generic
Julia representation (Dict, Array, etc.) (1st method), or construct an instance of type `T` from JSON input (2nd method).
Specifically, the following default materializations are used for untyped materialization:
  * JSON object => `Dict{String, Any}`
  * JSON array => `Vector{Any}`
  * JSON string => `String`
  * JSON number => `Int64`, `Int128`, `BigInt`, `Float64`, or `BigFloat`
  * JSON true => `true`
  * JSON false => `false`
  * JSON null => `nothing`

Alternatively, a `types::JSONBase.Types` keyword argument can be passed where different defaults
are used, like:
  * `types=JSONBase.Types(objectype=Vector{Pair{String, Any}})`
  * `types=JSONBase.Types(arraytype=Set{Any})`
  * `types=JSONBase.Types(stringtype=Symbol)`

When a type `T` is given for materialization, there are 3 construction "strategies" available:
  * `JSONBase.mutable(T)`: an instance is constructed via `T()`, then fields are set via `setproperty!(obj, field, value)`
  * `JSONBase.kwdef(T)`: an instance is constructed via `T(; field=value...)`, i.e. passed as keyword argumnents to the type constructor
  * Default: an instance is constructed by passing `T(val1, val2, ...)` to the type constructor
    values are matched on JSON object keys to field names; this corresponds to the "default" constructor
    structs have in Julia

Supported keyword arguments include:
  * `jsonlines`: 
  * `float64`: 
  * `types`: 
"""
function materialize end

"""
    JSONBase.materialize!(json, x)

Similar to [`materialize`](@ref), but materializes into an existing object `x`,
which supports the "mutable" strategy for construction; that is,
JSON object keys are matched to field names and `setpropty!(x, field, value)` is called.
"""

materialize(io::Union{IO, Base.AbstractCmd}, ::Type{T}=Any; kw...) where {T} = materialize(Base.read(io), T; kw...)
materialize!(io::Union{IO, Base.AbstractCmd}, x; kw...) = materialize!(Base.read(io), x; kw...)
materialize(io::IOStream, ::Type{T}=Any; kw...) where {T} = materialize(Mmap.mmap(io), T; kw...)
materialize!(io::IOStream, x; kw...) = materialize!(Mmap.mmap(io), x; kw...)

materialize(buf::Union{AbstractVector{UInt8}, AbstractString}, ::Type{T}=Any; types::Type{Types{O, A, S}}=TYPES, kw...) where {T, O, A, S} =
    materialize(lazy(buf; kw...), T; types)
materialize!(buf::Union{AbstractVector{UInt8}, AbstractString}, x; types::Type{Types{O, A, S}}=TYPES, kw...) where {O, A, S} =
    materialize!(lazy(buf; kw...), x, types)

mutable struct AnyClosure
    x::Any
    AnyClosure() = new()
end

@inline (f::AnyClosure)(x) = f.x = x

@inline function materialize(x::LazyValue, ::Type{T}=Any; types::Type{Types{O, A, S}}=TYPES) where {T, O, A, S}
    y = AnyClosure()
    pos = materialize(y, x, T, types)
    checkendpos(x, pos, T)
    return y.x
end

# for LazyValue, if x started at the beginning of the JSON input,
# then we want to ensure that the entire input was consumed
# and error if there are any trailing invalid JSON characters
@inline checkendpos(x::LazyValue, pos, ::Type{T}) where {T} = getpos(x) == 1 && _checkendpos(x, pos, T)

function _checkendpos(x::LazyValue, pos, ::Type{T}) where {T}
    buf = getbuf(x)
    len = getlength(buf)
    if pos <= len
        b = getbyte(buf, pos)
        while b == UInt8('\t') || b == UInt8(' ') || b == UInt8('\n') || b == UInt8('\r')
            pos += 1
            pos > len && break
            b = getbyte(buf, pos)
        end
    end
    if (pos - 1) != len
        invalid(InvalidChar, buf, pos, T)
    end
    return nothing
end

function materialize(x::BinaryValue, ::Type{T}=Any; types::Type{Types{O, A, S}}=TYPES) where {T, O, A, S}
    local y
    materialize(_x -> (y = _x), x, T, types)
    return y
end

struct GenericObjectClosure{O, T}
    keyvals::O
end

struct GenericObjectValFunc{O, K, T}
    keyvals::O
    key::K
end

@inline (f::GenericObjectValFunc{O, K, T})(x) where {O, K, T} =
    addkeyval!(f.keyvals, tostring(_keytype(f.keyvals, T), f.key), x)

# `dictlike` controls whether a type eagerly "slurps up"
# all key-value pairs from a JSON object, otherwise
# the type will recurse into materialize(json, T)
dictlike(::Type{<:AbstractDict}) = true
dictlike(::Type{<:AbstractVector{<:Pair}}) = true
dictlike(_) = false

@inline addkeyval!(d::AbstractDict, k, v) = d[k] = v
@inline addkeyval!(d::AbstractVector, k, v) = push!(d, k => v)

_keytype(d::AbstractDict, ::Type{Types{O, A, S}}) where {O, A, S} = keytype(d)
_keytype(d::AbstractVector{<:Pair}, ::Type{Types{O, A, S}}) where {O, A, S} = eltype(d).parameters[1]
_keytype(d, ::Type{Types{O, A, S}}) where {O, A, S} = S
_valtype(d::AbstractDict) = valtype(d)
_valtype(d::AbstractVector{<:Pair}) = eltype(d).parameters[2]
_valtype(_) = Any

@inline function (f::GenericObjectClosure{O, T})(key, val) where {O, T}
    pos = _materialize(GenericObjectValFunc{O, typeof(key), T}(f.keyvals, key), val, _valtype(f.keyvals), T)
    return Continue(pos)
end

struct GenericArrayClosure{A, T}
    arr::A
end

struct GenericArrayValFunc{A, T}
    arr::A
end

@inline (f::GenericArrayValFunc{A, T})(x) where {A, T} =
    push!(f.arr, x)

@inline function (f::GenericArrayClosure{A, T})(i, val) where {A, T}
    pos = _materialize(GenericArrayValFunc{A, T}(f.arr), val, eltype(A), T)
    return Continue(pos)
end

struct ArrayLengthClosure
    len::Ptr{Int}
end

@inline function (f::ArrayLengthClosure)(i, val)
    unsafe_store!(f.len, i)
    return Continue()
end

struct MatrixClosure{A, T}
    mat::A
    col::Int
end

struct MatrixValFunc{A}
    mat::A
    col::Int
    row::Int
end

@inline (f::MatrixValFunc{A})(x) where {A} = setindex!(f.mat, x, f.row, f.col)

@inline function (f::MatrixClosure{A, T})(i, val) where {A, T}
    # i is our row index
    pos = _materialize(MatrixValFunc(f.mat, f.col, i), val, eltype(A), T)
    return Continue(pos)
end

initarray(::Type{A}) where {A <: AbstractSet} = A()
initarray(::Type{A}) where {A <: AbstractVector} = A(undef, 0)

function _materialize(valfunc::F, x::Union{LazyValue, BinaryValue}, ::Type{T}=Any, types::Type{Types{O, A, S}}=TYPES) where {F, T, O, A, S}
    return materialize(valfunc, x, T, types)
end

# Note: when calling this method manually, we don't do the checkendpos check
# which means if the input JSON has invalid trailing characters, no error will be thrown
@inline function materialize(valfunc::F, x::Union{LazyValue, BinaryValue}, ::Type{T}=Any, types::Type{Types{O, A, S}}=TYPES) where {F, T, O, A, S}
    type = gettype(x)
    if type == JSONTypes.OBJECT
        if T === Any || dictlike(T)
            d = O()
            pos = parseobject(GenericObjectClosure{O, types}(d), x).pos
            valfunc(d)
            return pos
        else
            if mutable(T)
                y = T()
                pos = materialize!(x, y, types)
                valfunc(y)
                return pos
            elseif kwdef(T)
                kws = Pair{Symbol, Any}[]
                c = KwClosure{T, types}(kws)
                pos = parseobject(c, x).pos
                y = T(; kws...)
                valfunc(y)
                return pos
            else
                # struct fallback
                N = fieldcount(T)
                vec = Vector{Any}(undef, N)
                c = StructClosure{T, types}(vec)
                pos = parseobject(c, x).pos
                constructor = T <: NamedTuple ? ((x...) -> T(tuple(x...))) : T
                construct(T, constructor, vec, valfunc)
                return pos
            end
        end
    elseif type == JSONTypes.ARRAY
        if T === Any
            a = initarray(A)
            pos = parsearray(GenericArrayClosure{A, types}(a), x).pos
            valfunc(a)
            return pos
        elseif T <: Matrix
            # special-case Matrix
            # must be an array of arrays, where each array element
            # is the same length
            # we need to peek ahead to figure out the size
            sz = parsearray(x) do i, v
                # v is the 1st column of our matrix
                # but we really just want to know the length
                gettype(v) == JSONTypes.ARRAY || throw(ArgumentError("expected array of arrays for materializing: `$T`"))
                ref = Ref(0)
                c = ArrayLengthClosure(Base.unsafe_convert(Ptr{Int}, ref))
                GC.@preserve ref parsearray(c, v)
                # by returning the len here, we're short-circuiting the initial
                # parsearray call
                return unsafe_load(c.len)
            end
            a = T(undef, (sz, sz))
            # now we do the actual parsing to fill in our matrix
            cont = parsearray(x) do i, v
                # i is the column index of our matrix
                # v is the 1st column of our matrix
                c = MatrixClosure{T, types}(a, i)
                return parsearray(c, v)
            end
            valfunc(a)
            return cont.pos
        else
            a = initarray(T)
            pos = parsearray(GenericArrayClosure{T, types}(a), x).pos
            valfunc(a)
            return pos
        end
    elseif type == JSONTypes.STRING
        str, pos = parsestring(x)
        if T === Any
            valfunc(tostring(S, str))
        else
            valfunc(tostring(T, str))
        end
        return pos
    elseif x isa LazyValue && type == JSONTypes.NUMBER # only LazyValue
        return parsenumber(valfunc, x)
    elseif x isa BinaryValue && type == JSONTypes.INT # only BinaryValue
        return parseint(valfunc, x)
    elseif x isa BinaryValue && type == JSONTypes.FLOAT # only BinaryValue
        return parsefloat(valfunc, x)
    elseif type == JSONTypes.NULL
        if T !== Any && T >: Missing
            valfunc(missing)
        else
            valfunc(nothing)
        end
        return getpos(x) + (x isa BinaryValue ? 1 : 4)
    elseif type == JSONTypes.TRUE
        valfunc(true)
        return getpos(x) + (x isa BinaryValue ? 1 : 4)
    else
        @assert type == JSONTypes.FALSE "type = $type"
        valfunc(false)
        return getpos(x) + (x isa BinaryValue ? 1 : 5)
    end
end

struct ValFuncClosure{F}
    i::Int
    fname::Symbol
    valfunc::F
end

@inline function (f::ValFuncClosure)(val)
    f.valfunc(f.i, f.fname, val)
    return
end

# NOTE: care needs to be taken in applyfield to not inline too much,
# since we're essentially duplicating the inner quote block for each
# field of struct T
# applyfield is used by each struct materialization strategy (Mutable, KwDef, Struct)
# it takes a `key` and `val` parsed from json, then compares `key`
# with field names in `T` and when a match is found, determines how
# to materialize `val` (via materialize)
# passing `valfunc` along to be applied to the final materialized value
@generated function applyfield(::Type{T}, types::Type{S}, key, val, valfunc::F) where {T, S <: Types, F}
    N = fieldcount(T)
    ex = quote
        return Continue()
    end
    for i = 1:N
        fname = fieldname(T, i)
        ftype = fieldtype(T, i)
        str = String(fname)
        pushfirst!(ex.args, quote
            field = get(fds, $(Meta.quot(fname)), nothing)
            str = field !== nothing && haskey(field, :jsonkey) ? field.jsonkey : $str
            if Selectors.eq(key, str)
                c = ValFuncClosure($i, $(Meta.quot(fname)), valfunc)
                pos = _materialize(c, val, $ftype, types)
                return Continue(pos)
            end
        end)
    end
    pushfirst!(ex.args, :(fds = fields($T)))
    pushfirst!(ex.args, :(Base.@_inline_meta))
    # str = sprint(show, ex)
    # println(str)
    return ex
end

@inline function getval(::Type{T}, vec, nm, i) where {T}
    isassigned(vec, i) && return vec[i] # big perf win to do ::fieldtype(T, i) here, but at the cost of not allowing convert to work in constructor
    fds = fields(T)
    field = get(fds, nm, nothing)
    return field !== nothing && haskey(field, :default) ? field.default : nothing
end

@generated function construct(::Type{T}, constructor, vec, valfunc::F) where {T, F}
    N = fieldcount(T)
    ex = quote
        valfunc(constructor())
        return
    end
    cons = ex.args[2].args[2]
    for i = 1:N
        push!(cons.args, :(getval(T, vec, $(Meta.quot(fieldname(T, i))), $i)))
    end
    return ex
end

struct StructClosure{T, types}
    vec::Vector{Any}
end

struct ApplyStruct
    vec::Vector{Any}
end

@inline (f::ApplyStruct)(i, k, v) = f.vec[i] = v
@inline (f::StructClosure{T, types})(key, val) where {T, types} = applyfield(T, types, key, val, ApplyStruct(f.vec))

struct KwClosure{T, types}
    kws::Vector{Pair{Symbol, Any}}
end

struct ApplyKw
    kws::Vector{Pair{Symbol, Any}}
end

@inline (f::ApplyKw)(i, k, v) = push!(f.kws, k => v)
@inline (f::KwClosure{T, types})(key, val) where {T, types} = applyfield(T, types, key, val, ApplyKw(f.kws))

struct MutableClosure{T, types}
    x::T
end

struct ApplyMutable{T}
    x::T
end

@inline (f::ApplyMutable{T})(i, k, v) where {T} = setproperty!(f.x, k, v)
@inline (f::MutableClosure{T, types})(key, val) where {T, types} = applyfield(T, types, key, val, ApplyMutable(f.x))

function materialize!(x::Union{LazyValue, BinaryValue}, ::Type{T}, types::Type{Types{O, A, S}}=TYPES) where {T, O, A, S}
    y = T()
    materialize!(x, y, types)
    return y
end

function materialize!(x::Union{LazyValue, BinaryValue}, y::T, types::Type{Types{O, A, S}}=TYPES) where {T, O, A, S}
    c = MutableClosure{T, types}(y)
    return parseobject(c, x).pos
end
