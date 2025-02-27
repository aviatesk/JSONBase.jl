"""
    JSONBase.lazy(json; kw...)

Detect the initial JSON value in `json`, returning a
`JSONBase.LazyValue` instance. `json` input can be:
  * `AbstractString`
  * `AbstractVector{UInt8}`
  * `IO` stream
  * `Base.AbstractCmd`

The `JSONBase.LazyValue` supports the "selection" syntax
for lazily navigating the JSON value. Lazy values can be
materialized via:
  * `JSONBase.binary`: an efficient, read-only binary format
  * `JSONBase.materialize(x)`: a generic Julia representation (Dict, Array, etc.)
  * `JSONBase.materialize(x, T)`: construct an instance of user-provided `T` from JSON

Currently supported keyword arguments include:
  * `float64`: for parsing all json numbers as Float64 instead of inferring int vs. float;
    also allows parsing `NaN`, `Inf`, and `-Inf` since they are otherwise invalid JSON
  * `jsonlines`: treat the `json` input as an implicit JSON array,
    delimited by newlines, each element being parsed from each row/line in the input

Note that validation is only fully done on `null`, `true`, and `false`,
while other values are only lazily inferred from the first non-whitespace character:
  * `'{'`: JSON object
  * `'['`: JSON array
  * `'"'`: JSON string
  * `'0'`-`'9'` or `'-'`: JSON number

Further validation for these values is done later via `JSONBase.materialize`,
or via selection syntax calls on a `LazyValue`.
"""
function lazy end

lazy(io::Union{IO, Base.AbstractCmd}; kw...) = lazy(Base.read(io); kw...)
lazy(io::IOStream; kw...) = lazy(Mmap.mmap(io); kw...)

@inline function lazy(buf::Union{AbstractVector{UInt8}, AbstractString}; kw...)
    len = getlength(buf)
    if len == 0
        error = UnexpectedEOF
        pos = 0
        @goto invalid
    end
    pos = 1
    @nextbyte
    return lazy(buf, pos, len, b, Options(; kw...))

@label invalid
    invalid(error, buf, pos, Any)
end

"""
    JSONBase.LazyValue

A lazy representation of a JSON value. The `LazyValue` type
supports the "selection" syntax for lazily navigating the JSON value.
Lazy values can be materialized via:
  * `JSONBase.binary`: an efficient, read-only binary format
  * `JSONBase.materialize`: a generic Julia representation (Dict, Array, etc.)
  * `JSONBase.materialize`: construct an instance of user-provided `T` from JSON
"""
struct LazyValue{T}
    buf::T
    pos::Int
    type::JSONTypes.T
    opts::Options
end

# only used for showing LazyValue
struct LazyObject{T} <: AbstractDict{String, LazyValue}
    buf::T
    pos::Int
    opts::Options
end

struct LazyArray{T} <: AbstractVector{LazyValue}
    buf::T
    pos::Int
    opts::Options
end

const LazyValues{T} = Union{LazyValue{T}, LazyObject{T}, LazyArray{T}}

getlength(x::LazyValues) = getlength(getbuf(x))

gettype(::LazyObject) = JSONTypes.OBJECT

struct LengthClosure
    len::Ptr{Int}
end

@inline function (f::LengthClosure)(_, _)
    unsafe_store!(f.len, unsafe_load(f.len) + 1)
    return Continue()
end

function Base.length(x::LazyObject)
    ref = Ref(0)
    lc = LengthClosure(Base.unsafe_convert(Ptr{Int}, ref))
    GC.@preserve ref begin
        applyobject(lc, x)
        return unsafe_load(lc.len)
    end
end

struct IterateObjectClosure
    kvs::Vector{Pair{String, LazyValue}}
end

@inline function (f::IterateObjectClosure)(k, v)
    push!(f.kvs, tostring(String, k) => v)
    return Continue()
end

function Base.iterate(x::LazyObject, st=nothing)
    if st === nothing
        # first iteration
        kvs = Pair{String, LazyValue}[]
        applyobject(IterateObjectClosure(kvs), x)
        i = 1
    else
        kvs = st[1]
        i = st[2]
    end
    i > length(kvs) && return nothing
    return kvs[i], (kvs, i + 1)
end

gettype(::LazyArray) = JSONTypes.ARRAY

Base.IndexStyle(::Type{<:LazyArray}) = Base.IndexLinear()

function Base.size(x::LazyArray)
    ref = Ref(0)
    alc = ArrayLengthClosure(Base.unsafe_convert(Ptr{Int}, ref))
    GC.@preserve ref begin
        applyarray(alc, x)
        return (unsafe_load(alc.len),)
    end
end

Base.isassigned(x::LazyArray, i::Int) = true
Base.getindex(x::LazyArray, i::Int) = Selectors._getindex(x, i)
API.applyeach(f, x::LazyArray) = applyarray(f, x)

function Base.show(io::IO, x::LazyValue)
    T = gettype(x)
    if T == JSONTypes.OBJECT
        compact = get(io, :compact, false)::Bool
        lo = LazyObject(getbuf(x), getpos(x), getopts(x))
        if compact
            show(io, lo)
        else
            io = IOContext(io, :compact => true)
            show(io, MIME"text/plain"(), lo)
        end
    elseif T == JSONTypes.ARRAY
        compact = get(io, :compact, false)::Bool
        la = LazyArray(getbuf(x), getpos(x), getopts(x))
        if compact
            show(io, la)
        else
            io = IOContext(io, :compact => true)
            show(io, MIME"text/plain"(), la)
        end
    elseif T == JSONTypes.STRING
        str, _ = applystring(nothing, x)
        print(io, "JSONBase.LazyValue(", repr(tostring(String, str)), ")")
    elseif T == JSONTypes.NULL
        print(io, "JSONBase.LazyValue(nothing)")
    else
        print(io, "JSONBase.LazyValue(", materialize(x), ")")
    end
end

# core method that detects what JSON value is at the current position
# and immediately returns an appropriate LazyValue instance
@inline function lazy(buf, pos, len, b, opts)
    if opts.jsonlines
        return LazyValue(buf, pos, JSONTypes.ARRAY, opts)
    elseif b == UInt8('{')
        return LazyValue(buf, pos, JSONTypes.OBJECT, opts)
    elseif b == UInt8('[')
        return LazyValue(buf, pos, JSONTypes.ARRAY, opts)
    elseif b == UInt8('"')
        return LazyValue(buf, pos, JSONTypes.STRING, opts)
    elseif b == UInt8('n') && pos + 3 <= len &&
        getbyte(buf,pos + 1) == UInt8('u') &&
        getbyte(buf,pos + 2) == UInt8('l') &&
        getbyte(buf,pos + 3) == UInt8('l')
        return LazyValue(buf, pos, JSONTypes.NULL, opts)
    elseif b == UInt8('t') && pos + 3 <= len &&
        getbyte(buf,pos + 1) == UInt8('r') &&
        getbyte(buf,pos + 2) == UInt8('u') &&
        getbyte(buf,pos + 3) == UInt8('e')
        return LazyValue(buf, pos, JSONTypes.TRUE, opts)
    elseif b == UInt8('f') && pos + 4 <= len &&
        getbyte(buf,pos + 1) == UInt8('a') &&
        getbyte(buf,pos + 2) == UInt8('l') &&
        getbyte(buf,pos + 3) == UInt8('s') &&
        getbyte(buf,pos + 4) == UInt8('e')
        return LazyValue(buf, pos, JSONTypes.FALSE, opts)
    elseif b == UInt8('-') || (UInt8('0') <= b <= UInt8('9')) || (opts.float64 && (b == UInt8('N') || b == UInt8('I') || b == UInt8('+')))
        return LazyValue(buf, pos, JSONTypes.NUMBER, opts)
    else
        error = InvalidJSON
        @goto invalid
    end
@label invalid
    invalid(error, buf, pos, Any)
end

# non-inlined version of applyobject
_applyobject(f::F, x) where {F} = applyobject(f, x)

# core JSON object parsing function
# takes a `keyvalfunc` that is applied to each key/value pair
# `keyvalfunc` is provided a PtrString => LazyValue pair
# to materialize the key, call `tostring(key)`
# this is done automatically in selection syntax via `keyvaltostring` transformer
# returns an Continue(pos) value that notes the next position where parsing should
# continue (selection syntax requires Continue to be returned from applyeach)
@inline function applyobject(keyvalfunc::F, x::LazyValues) where {F}
    pos = getpos(x)
    buf = getbuf(x)
    len = getlength(buf)
    opts = getopts(x)
    b = getbyte(buf, pos)
    if b != UInt8('{')
        error = ExpectedOpeningObjectChar
        @goto invalid
    end
    pos += 1
    @nextbyte
    if b == UInt8('}')
        return Continue(pos + 1)
    end
    while true
        # applystring returns key as a PtrString
        key, pos = applystring(nothing, LazyValue(buf, pos, JSONTypes.STRING, getopts(x)))
        @nextbyte
        if b != UInt8(':')
            error = ExpectedColon
            @goto invalid
        end
        pos += 1
        @nextbyte
        # we're now positioned at the start of the value
        val = lazy(buf, pos, len, b, opts)
        ret = keyvalfunc(key, val)
        # if ret is not an Continue, then we're 
        # short-circuiting parsing via e.g. selection syntax
        # so return immediately
        ret isa Continue || return ret
        # if keyvalfunc didn't materialize `val` and return an
        # updated `pos`, then we need to skip val ourselves
        pos = ret.pos == 0 ? skip(val) : ret.pos
        @nextbyte
        if b == UInt8('}')
            return Continue(pos + 1)
        elseif b != UInt8(',')
            error = ExpectedComma
            @goto invalid
        end
        pos += 1 # move past ','
        @nextbyte
    end
@label invalid
    invalid(error, buf, pos, "object")
end

# jsonlines is unique because it's an *implicit* array
# so newlines are valid delimiters (not ignored whitespace)
# and EOFs are valid terminators (not errors)
# these checks are injected after we've processed the "line"
# so we need to check for EOFs and newlines
macro jsonlines_checks()
    esc(quote
        # if we're at EOF, then we're done
        pos > len && return Continue(pos)
        # now we want to ignore whitespace, but *not* newlines
        b = getbyte(buf, pos)
        while b == UInt8(' ') || b == UInt8('\t')
            pos += 1
            pos > len && return Continue(pos)
            b = getbyte(buf, pos)
        end
        # any combo of '\r', '\n', or '\r\n' is a valid delimiter
        foundr = false
        if b == UInt8('\r')
            foundr = true
            pos += 1
            pos > len && return Continue(pos)
            b = getbyte(buf, pos)
        end
        if b == UInt8('\n')
            pos += 1
            pos > len && return Continue(pos)
            b = getbyte(buf, pos)
        elseif !foundr
            # if we didn't find a newline and we're not EOF
            # then that's an error; only whitespace, newlines,
            # and EOFs are valid in between lines
            error = ExpectedNewline
            @goto invalid
        end
        while b == UInt8(' ') || b == UInt8('\t')
            pos += 1
            pos > len && return Continue(pos)
            b = getbyte(buf, pos)
        end
    end)
end

# non-inlined version of applyarray
_applyarray(f::F, x) where {F} = applyarray(f, x)

# core JSON array parsing function
# takes a `keyvalfunc` that is applied to each index => value element
# `keyvalfunc` is provided a Int => LazyValue pair
# applyeach always requires a key-value pair function
# so we use the index as the key
# returns an Continue(pos) value that notes the next position where parsing should
# continue (selection syntax requires Continue to be returned from applyeach)
@inline function applyarray(keyvalfunc::F, x::LazyValues) where {F}
    pos = getpos(x)
    buf = getbuf(x)
    len = getlength(buf)
    opts = getopts(x)
    jsonlines = opts.jsonlines
    b = getbyte(buf, pos)
    if !jsonlines
        if b != UInt8('[')
            error = ExpectedOpeningArrayChar
            @goto invalid
        end
        pos += 1
        @nextbyte
        if b == UInt8(']')
            return Continue(pos + 1)
        end
    else
        # for jsonlines, we need to make sure that recursive
        # lazy values *don't* consider individual lines *also*
        # to be jsonlines
        opts = withopts(opts, jsonlines=false)
    end
    i = 1
    while true
        # we're now positioned at the start of the value
        val = lazy(buf, pos, len, b, opts)
        ret = keyvalfunc(i, val)
        ret isa Continue || return ret
        pos = ret.pos == 0 ? skip(val) : ret.pos
        if jsonlines
            @jsonlines_checks
        else
            @nextbyte
            if b == UInt8(']')
                return Continue(pos + 1)
            elseif b != UInt8(',')
                error = ExpectedComma
                @goto invalid
            end
            i += 1
            pos += 1 # move past ','
            @nextbyte
        end
    end

@label invalid
    invalid(error, buf, pos, "array")
end

# core JSON string parsing function
# returns a PtrString and the next position to parse
# a PtrString is a semi-lazy, internal-only representation
# that notes whether escape characters were encountered while parsing
# or not. It allows materialize, _binary, etc. to deal
# with the string data appropriately without forcing a String allocation
# PtrString should NEVER be visible to users though!
@inline function applystring(f::F, x::LazyValue) where {F}
    buf, pos = getbuf(x), getpos(x)
    len, b = getlength(buf), getbyte(buf, pos)
    if b != UInt8('"')
        error = ExpectedOpeningQuoteChar
        @goto invalid
    end
    pos += 1
    spos = pos
    escaped = false
    @nextbyte
    while b != UInt8('"')
        if b == UInt8('\\')
            # skip next character
            escaped = true
            pos += 2
        else
            pos += 1
        end
        @nextbyte(false)
    end
    str = PtrString(pointer(buf, spos), pos - spos, escaped)
    if f === nothing
        return str, pos + 1
    else
        f(str)
        return pos + 1
    end

@label invalid
    invalid(error, buf, pos, "string")
end

_applynumber(f::F, x::LazyValue) where {F} = applynumber(f, x)

# core JSON number parsing function
# we rely on functionality in Parsers to help infer what kind
# of number we're parsing; valid return types include:
# Int64, Int128, BigInt, Float64 or BigFloat
@inline function applynumber(valfunc::F, x::LazyValue) where {F}
    buf, pos = getbuf(x), getpos(x)
    len = getlength(buf)
    b = getbyte(buf, pos)
    # if user passed `float64=true`, then we hard-code only parse Float64
    if getopts(x).float64
        res = Parsers.xparse2(Float64, buf, pos, len)
        if Parsers.invalid(res.code)
            error = InvalidNumber
            @goto invalid
        end
        valfunc(res.val)
        return pos + res.tlen
    else
        pos, code = Parsers.parsenumber(buf, pos, len, b, valfunc)
        if Parsers.invalid(code)
            error = InvalidNumber
            @goto invalid
        end
    end
    return pos

@label invalid
    invalid(error, buf, pos, "number")
end

# efficiently skip over a JSON value
# for object/array/number, we pass a no-op keyvalfunc (pass)
# to applyobject/applyarray/applynumber
# for string, we just ignore the returned PtrString
# and for bool/null, we just skip the appropriate number of bytes
@inline function skip(x::LazyValue)
    T = gettype(x)
    if T == JSONTypes.OBJECT
        return _applyobject(pass, x).pos
    elseif T == JSONTypes.ARRAY
        return _applyarray(pass, x).pos
    elseif T == JSONTypes.STRING
        pos = applystring(pass, x)
        return pos
    elseif T == JSONTypes.NUMBER
        return _applynumber(pass, x)
    elseif T == JSONTypes.TRUE
        return getpos(x) + 4
    elseif T == JSONTypes.FALSE
        return getpos(x) + 5
    elseif T == JSONTypes.NULL
        return getpos(x) + 4
    end
end
