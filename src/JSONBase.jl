module JSONBase

export Selectors

using Mmap, Dates, UUIDs
using Parsers

# helper accessors
getbuf(x) = getfield(x, :buf)
getpos(x) = getfield(x, :pos)
gettape(x) = getfield(x, :tape)
gettype(x) = getfield(x, :type)
getopts(x) = getfield(x, :opts)

include("utils.jl")

include("interfaces.jl")
using .API

pass(args...) = Continue(0)

include("selectors.jl")
using .Selectors

include("lazy.jl")
include("binary.jl")
include("materialize.jl")
include("json.jl")

# a helper higher-order function that converts an
# API.applyeach function that operates potentially on a
# PtrString to one that operates on a String
keyvaltostring(f) = (k, v) -> f(tostring(String, k), v)

const Values = Union{LazyValue, BinaryValue}

# allow LazyValue/BinaryValue to participate in
# selection syntax by overloading applyeach
function API.applyeach(f, x::Values)
    if gettype(x) == JSONTypes.OBJECT
        return applyobject(keyvaltostring(f), x)
    elseif gettype(x) == JSONTypes.ARRAY
        return applyarray(f, x)
    else
        throw(ArgumentError("`$x` is not an object or array and not eligible for selection syntax"))
    end
end

Base.getindex(x::Values) = materialize(x)
Selectors.objectlike(x::Values) = gettype(x) == JSONTypes.OBJECT
API.arraylike(x::Values) = gettype(x) == JSONTypes.ARRAY

# this defines convenient getindex/getproperty methods
Selectors.@selectors LazyValue
Selectors.@selectors BinaryValue

end # module

#TODO
 # 3-5 common JSON processing tasks/workflows
   # eventually in docs
   # use to highlight selection syntax
   # various conversion functions
     # working w/ small JSON
       # convert to Dict
       # pick 1 or 2 properties out
       # convert to struct
     # abstract JSON
       # use type field to figure out concrete subtype
       # convert to concrete struct
     # large jsonlines/object/array production processing
       # iterate each line: lazy, binary, materialize
       # start with lazy, API.applyeach on LazyValue
       # preallocate tape buffer, call binary! w/ preallocated buffer
       # in keyvalfunc to API.applyeach,
       # then call materialize
     # large, deeply nested json structures
       # use selection syntax to lazily navigate
       # then binary, materialize, materialize
     # how to form json
       # create Dict/NamedTuple/Array and call tojson
       # use struct and call tojson
       # support jsonlines output
 # package docs
 # topretty
 # allow materialize on any ObjectLike? i.e. Dicts? (would need applyobject on Dict)
 # checkout JSON5, Amazon Ion?