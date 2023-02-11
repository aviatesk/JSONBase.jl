"""
    JSONBase.tolazy(json; kw...)

Detect the initial JSON value in `json`, returning a
`JSONBase.LazyValue` instance. `json` input can be:
  * `AbstractString`
  * `AbstractVector{UInt8}`
  * `IO` stream
  * `Base.AbstractCmd`

The `JSONBase.LazyValue` supports the "selection" syntax
for lazily navigating the JSON value. Lazy values can be
materialized via:
  * `JSONBase.tobjson`: an efficient, read-only binary format
  * `JSONBase.togeneric`: a generic Julia representation (Dict, Array, etc.)
  * `JSONBase.tostruct`: construct an instance of user-provided `T` from JSON

Currently supported keyword arguments include:
  * `float64`: for parsing all json numbers as Float64 instead of inferring int vs. float
"""
function tolazy end

tolazy(io::Union{IO, Base.AbstractCmd}; kw...) = tolazy(Base.read(io); kw...)

function tolazy(buf::Union{AbstractVector{UInt8}, AbstractString}; kw...)
    len = getlength(buf)
    if len == 0
        error = UnexpectedEOF
        pos = 0
        @goto invalid
    end
    pos = 1
    @nextbyte
    return tolazy(buf, pos, len, b, Options(; kw...))

@label invalid
    invalid(error, buf, pos, Any)
end

"""
    JSONBase.LazyValue

A lazy representation of a JSON value. The `LazyValue` type
supports the "selection" syntax for lazily navigating the JSON value.
Lazy values can be materialized via:
  * `JSONBase.tobjson`: an efficient, read-only binary format
  * `JSONBase.togeneric`: a generic Julia representation (Dict, Array, etc.)
  * `JSONBase.tostruct`: construct an instance of user-provided `T` from JSON
"""
struct LazyValue{T}
    buf::T
    pos::Int
    type::JSONTypes.T
    opts::Options
end

getlength(x::LazyValue) = getlength(getbuf(x))

function Base.show(io::IO, x::LazyValue)
    print(io, "JSONBase.LazyValue(", gettype(x), ")")
end

# TODO: change this to tobjson
Base.getindex(x::LazyValue) = togeneric(x)

API.JSONType(x::LazyValue) = gettype(x) == JSONTypes.OBJECT ? API.ObjectLike() :
    gettype(x) == JSONTypes.ARRAY ? API.ArrayLike() : nothing

# core method that detects what JSON value is at the current position
# and immediately returns an appropriate LazyValue instance
function tolazy(buf, pos, len, b, opts)
    if b == UInt8('{')
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
    elseif b == UInt8('-') || (UInt8('0') <= b <= UInt8('9'))
        #TODO: have relaxed_number parsing keyword arg to
        # allow leading '+', 'Inf', 'NaN', etc.?
        return LazyValue(buf, pos, JSONTypes.NUMBER, opts)
    else
        error = InvalidJSON
        @goto invalid
    end
@label invalid
    invalid(error, buf, pos, Any)
end

# core JSON object parsing function
# takes a `keyvalfunc` that is applied to each key/value pair
# `keyvalfunc` is provided a PtrString => LazyValue pair
# to materialize the key, call `tostring(key)`
# this is done automatically in selection syntax via `keyvaltostring` transformer
# returns an API.Continue(pos) value that notes the next position where parsing should
# continue (selection syntax requires API.Continue to be returned from foreach)
@inline function parseobject(x::LazyValue, keyvalfunc::F) where {F}
    pos = getpos(x)
    buf = getbuf(x)
    len = getlength(buf)
    b = getbyte(buf, pos)
    if b != UInt8('{')
        error = ExpectedOpeningObjectChar
        @goto invalid
    end
    pos += 1
    @nextbyte
    if b == UInt8('}')
        return API.Continue(pos + 1)
    end
    while true
        # parsestring returns key as a PtrString
        key, pos = parsestring(LazyValue(buf, pos, JSONTypes.STRING, getopts(x)))
        @nextbyte
        if b != UInt8(':')
            error = ExpectedColon
            @goto invalid
        end
        pos += 1
        @nextbyte
        # we're now positioned at the start of the value
        val = tolazy(buf, pos, len, b, getopts(x))
        ret = keyvalfunc(key, val)
        # if ret is not an API.Continue, then we're 
        # short-circuiting parsing via selection syntax
        # so return immediately
        ret isa API.Continue || return ret
        # if keyvalfunc didn't materialize `val` and return an
        # updated `pos`, then we need to skip val ourselves
        pos = ret.pos == 0 ? skip(val) : ret.pos
        @nextbyte
        if b == UInt8('}')
            return API.Continue(pos + 1)
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

# core JSON array parsing function
# takes a `keyvalfunc` that is applied to each index => value element
# `keyvalfunc` is provided a Int => LazyValue pair
# API.foreach always requires a key-value pair function
# so we use the index as the key
# returns an API.Continue(pos) value that notes the next position where parsing should
# continue (selection syntax requires API.Continue to be returned from foreach)
@inline function parsearray(x::LazyValue, keyvalfunc::F) where {F}
    pos = getpos(x)
    buf = getbuf(x)
    len = getlength(buf)
    b = getbyte(buf, pos)
    if b != UInt8('[')
        error = ExpectedOpeningArrayChar
        @goto invalid
    end
    pos += 1
    @nextbyte
    if b == UInt8(']')
        return API.Continue(pos + 1)
    end
    i = 1
    while true
        # we're now positioned at the start of the value
        val = tolazy(buf, pos, len, b, getopts(x))
        ret = keyvalfunc(i, val)
        ret isa API.Continue || return ret
        pos = ret.pos == 0 ? skip(val) : ret.pos
        @nextbyte
        if b == UInt8(']')
            return API.Continue(pos + 1)
        elseif b != UInt8(',')
            error = ExpectedComma
            @goto invalid
        end
        i += 1
        pos += 1 # move past ','
        @nextbyte
    end

@label invalid
    invalid(error, buf, pos, "array")
end

# core JSON string parsing function
# returns a PtrString and the next position to parse
# a PtrString is a semi-lazy, internal-only representation
# that notes whether escape characters were encountered while parsing
# or not. It allows _togeneric, _tobjson, etc. to deal
# with the string data appropriately without forcing a String allocation
# should NEVER be visible to users though!
@inline function parsestring(x::LazyValue)
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
    return PtrString(pointer(buf, spos), pos - spos, escaped), pos + 1

@label invalid
    invalid(error, buf, pos, "string")
end

# core JSON number parsing function
# we rely on functionality in Parsers to help infer what kind
# of number we're parsing; valid return types include:
# Int64, Int128, BigInt, Float64 or BigFloat
@inline function parsenumber(x::LazyValue, valfunc::F) where {F}
    buf, pos = getbuf(x), getpos(x)
    len = getlength(buf)
    b = getbyte(buf, pos)
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
# to parseobject/parsearray/parsenumber
# for string, we just ignore the returned PtrString
# and for bool/null, we call _togeneric since it
# is already efficient for skipping
function skip(x::LazyValue)
    T = gettype(x)
    if T == JSONTypes.OBJECT
        return parseobject(x, pass).pos
    elseif T == JSONTypes.ARRAY
        return parsearray(x, pass).pos
    elseif T == JSONTypes.STRING
        _, pos = parsestring(x)
        return pos
    elseif T == JSONTypes.NUMBER
        return parsenumber(x, pass)
    else
        return _togeneric(x, pass)
    end
end
