module JSONBase

export Selectors

using Mmap, Dates, UUIDs
using Parsers

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

keyvaltostring(f) = (k, v) -> f(tostring(String, k), v)

function API.foreach(f, x::Union{LazyValue, BinaryValue})
    if gettype(x) == JSONTypes.OBJECT
        return parseobject(keyvaltostring(f), x)
    elseif gettype(x) == JSONTypes.ARRAY
        return parsearray(f, x)
    else
        throw(ArgumentError("`$x` is not an object or array and not eligible for selection syntax"))
    end
end

Selectors.@selectors LazyValue
Selectors.@selectors BinaryValue

end # module

#TODO
 # lower(T, k, v) and lift(T, k, v) consistency (always symbols? always strings?)
 # ObjectLike, ArrayLike, JSONType, dictlike unification
   # also clarify expected interfaces:
     # for writing: strings, numbers, objects, arrays, etc
     # for reading: strings, numbers, objects, arrays, etc
 # LazyObject/LazyArray/BinaryObject/BinaryArray to make them more convenient + display?
   # implement AbstractDict for LazyObject/BinaryObject
   # implement AbstractArray for LazyArray/BinaryArray
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
       # start with lazy, API.foreach on LazyValue
       # preallocate tape buffer, call binary! w/ preallocated buffer
       # in keyvalfunc to API.foreach,
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
 # allow materialize on any ObjectLike? i.e. Dicts? (would need parseobject on Dict)
 # checkout JSON5, Amazon Ion?