""" Syntax for a generalized algebraic theory (GAT).

Unlike instances of a theory, syntactic expressions don't necessarily satisfy
the equations of the theory. For example, the default syntax operations for the
`Category` theory don't form a category because they don't satisfy the category
laws, e.g.,
```
compose(f, id(A)) != compose(f)
```
Whether dependent types are enforced at runtime and whether expressions are
automatically brought to normal form depends on the particular syntax. In
general, a single theory may have many different syntaxes. The purpose of this
module to make the construction of syntax simple but flexible.
"""
module Syntax
export @syntax, BaseExpr, SyntaxDomainError, head, args, type_args, first, last,
  invoke_term, functor, to_json, parse_json, show_sexpr, show_unicode,
  show_unicode_infix, show_latex, show_latex_infix, show_latex_script

import Base: first, last, show, showerror, datatype_name, datatype_module
import Base.Meta: show_sexpr
using Match

using ..GAT: Context, Signature, TypeConstructor, TermConstructor, Typeclass
import ..GAT
import ..GAT: invoke_term
using ..Meta

# XXX: The special case for `UnionAll` wrappers is handled in `datatype_name`
# but not in `datatype_module`.
datatype_module(typ::UnionAll) = datatype_module(typ.body)

# Data types
############

""" Base type for expression in the syntax of a GAT.

We define Julia types for each *type constructor* in the theory, e.g., object,
morphism, and 2-morphism in the theory of 2-categories. Of course, Julia's
type system does not support dependent types, so the type parameters are
incorporated in the Julia types. (They are stored as extra data in the
expression instances.)
  
The concrete types are structurally similar to the core type `Expr` in Julia.
However, the *term constructor* is represented as a type parameter, rather than
as a `head` field. This makes dispatch using Julia's type system more
convenient.
"""
abstract type BaseExpr{T} end

head{T}(::BaseExpr{T}) = T
args(expr::BaseExpr) = expr.args
first(expr::BaseExpr) = first(args(expr))
last(expr::BaseExpr) = last(args(expr))
type_args(expr::BaseExpr) = expr.type_args

function Base.:(==)(e1::BaseExpr, e2::BaseExpr)
  head(e1) == head(e2) && args(e1) == args(e2) && type_args(e1) == type_args(e2)
end
function Base.hash(e::BaseExpr, h::UInt)
  hash(args(e), hash(head(e), h))
end

function show(io::IO, expr::BaseExpr)
  print(io, head(expr))
  print(io, "(")
  join(io, args(expr), ",")
  print(io, ")")
end
show(io::IO, expr::BaseExpr{:generator}) = print(io, first(expr))

struct SyntaxDomainError <: Exception
  constructor::Symbol
  args::Vector
end

function showerror(io::IO, exc::SyntaxDomainError)
  print(io, "Domain error in term constructor $(exc.constructor)(")
  join(io, exc.args, ",")
  print(io, ")")
end

# Syntax
########

""" Define a *syntax* system for a generalized algebraic theory (GAT).

A syntax system consists of Julia types (with top type `BaseExpr`) for each type
constructor in the signature, plus Julia functions for

1. *Generators*: creating new generator terms, e.g., objects or morphisms
2. *Accessors*: accessing type parameters, e.g., domains and codomains
3. *Term constructors*: applying term constructors, e.g., composition and
   monoidal products

Julia code for all this is generated by the macro. Any of the methods can be
overriden with custom simplification logic.
"""
macro syntax(syntax_head, mod_name, body=Expr(:block))
  @assert body.head == :block
  syntax_name, base_types = @match syntax_head begin
    Expr(:call, [name::Symbol, args...], _) => (name, args)
    name::Symbol => (name, [])
    _ => throw(ParseError("Ill-formed syntax signature $syntax_head"))
  end
  functions = map(parse_function, strip_lines(body).args)
  
  expr = Expr(:call, :syntax_code, Expr(:quote, syntax_name),
              esc(Expr(:ref, :Type, base_types...)), esc(mod_name), functions)
  Expr(:block,
    Expr(:call, esc(:eval), expr),
    :(Core.@__doc__ $(esc(syntax_name))))
end
function syntax_code(name::Symbol, base_types::Vector{Type}, mod::Module,
                     functions::Vector)
  class = mod.class()
  signature = class.signature
  
  # Generate module with syntax types and type/term generators.
  outer_mod = current_module()
  mod = Expr(:module, true, name,
    Expr(:block, [
      Expr(:using, map(Symbol, split(string(outer_mod), "."))...);
      Expr(:export, [cons.name for cons in signature.types]...);  
      :(signature() = $(GlobalRef(module_parent(mod), module_name(mod))));
      gen_types(signature, base_types);
      gen_type_accessors(signature);
      gen_term_generators(signature);
      gen_term_constructors(signature);
    ]...))
  
  # Generate toplevel functions.
  toplevel = []
  bindings = Dict{Symbol,Any}(
    c.name => Expr(:(.), name, QuoteNode(c.name)) for c in signature.types)
  bindings[:Super] = name
  syntax_fns = Dict(parse_function_sig(f) => f for f in functions)
  for f in interface(class)
    sig = parse_function_sig(f)
    if haskey(syntax_fns, sig)
      # Case 1: The method is overriden in the syntax body.
      expr = generate_function(replace_symbols(bindings, syntax_fns[sig]))
    elseif !isnull(f.impl)
      # Case 2: The method has a default implementation in the signature.
      expr = generate_function(replace_symbols(bindings, f))
    else
      # Case 3: Call the default syntax method.
      params = [ gensym("x$i") for i in eachindex(sig.types) ]
      call_expr = Expr(:call, sig.name, 
        [ Expr(:(::), p, t) for (p,t) in zip(params, sig.types) ]...)
      body = Expr(:call, Expr(:(.), name, QuoteNode(sig.name)), params...)
      f_impl = JuliaFunction(call_expr, f.return_type, body)
      # Inline these very short functions.
      expr = Expr(:macrocall, Symbol("@inline"),
                  generate_function(replace_symbols(bindings, f_impl)))
    end
    push!(toplevel, expr)
  end
  Expr(:toplevel, mod, toplevel...)
end

""" Complete set of Julia functions for a syntax system.
"""
function interface(class::Typeclass)::Vector{JuliaFunction}
  sig = class.signature
  [ GAT.interface(class);
    [ GAT.constructor(constructor_for_generator(cons), sig)
      for cons in sig.types ]; ]
end

""" Generate syntax type definitions.
"""
function gen_type(cons::TypeConstructor, base_type::Type=Any)::Expr
  base_expr = GlobalRef(Syntax, :BaseExpr)
  base_name = if base_type == Any
    base_expr
  else
    GlobalRef(datatype_module(base_type), datatype_name(base_type))
  end
  expr = :(struct $(cons.name){T} <: $base_name{T}
    args::Vector
    type_args::Vector{$base_expr}
  end)
  strip_lines(expr, recurse=true)
end
function gen_types(sig::Signature, base_types::Vector{Type})::Vector{Expr}
  if isempty(base_types)
    map(gen_type, sig.types)
  else
    map(gen_type, sig.types, base_types)
  end
end

""" Generate accessor methods for type parameters.
"""
function gen_type_accessors(cons::TypeConstructor)::Vector{Expr}
  fns = []
  sym = gensym(:x)
  for (i, param) in enumerate(cons.params)
    call_expr = Expr(:call, param, Expr(:(::), sym, cons.name))
    return_type = GAT.strip_type(cons.context[param])
    body = Expr(:ref, Expr(:(.), sym, QuoteNode(:type_args)), i)
    push!(fns, generate_function(JuliaFunction(call_expr, return_type, body)))
  end
  fns
end
function gen_type_accessors(sig::Signature)::Vector{Expr}
  vcat(map(gen_type_accessors, sig.types)...)
end

""" Generate methods for syntax term constructors.
"""
function gen_term_constructor(cons::TermConstructor, sig::Signature;
                              dispatch_type::Symbol=Symbol())::Expr
  head = GAT.constructor(cons, sig)
  call_expr, return_type = head.call_expr, get(head.return_type)
  if dispatch_type == Symbol()
    dispatch_type = cons.name
  end
  body = Expr(:block)
  
  # Create expression to check constructor domain.
  eqs = GAT.equations(cons, sig)
  if !isempty(eqs)
    clauses = [ Expr(:call,:(==),lhs,rhs) for (lhs,rhs) in eqs ]
    conj = foldr((x,y) -> Expr(:(&&),x,y), clauses)
    insert!(call_expr.args, 2,
      Expr(:parameters, Expr(:kw, :strict, false)))
    push!(body.args,
      Expr(:if,
        Expr(:(&&), :strict, Expr(:call, :(!), conj)),
        Expr(:call, :throw,
          Expr(:call, GlobalRef(Syntax, :SyntaxDomainError),
            Expr(:quote, cons.name),
            Expr(:vect, cons.params...)))))
  end
  
  # Create call to expression constructor.
  type_params = gen_term_constructor_params(cons, sig)
  push!(body.args,
    Expr(:call,
      Expr(:curly, return_type, Expr(:quote, dispatch_type)),
      Expr(:vect, cons.params...),
      Expr(:vect, type_params...)))
  
  generate_function(JuliaFunction(call_expr, return_type, body))
end
function gen_term_constructors(sig::Signature)::Vector{Expr}
  [ gen_term_constructor(cons, sig) for cons in sig.terms ]
end

""" Generate expressions for type parameters of term constructor.

Besides expanding the implicit variables, we must handle two annoying issues:

1. Add types for method dispatch where necessary (see `GAT.add_type_dispatch`)
   FIXME: We are currently only handling the nullary case (e.g., `munit()`).
   To handle the general case, we need to do basic type inference.

2. Rebind the term constructors to ensure that user overrides are preferred over
   the default term constructors.
"""
function gen_term_constructor_params(cons, sig)::Vector
  expr = GAT.expand_term_type(cons, sig)
  raw_params = @match expr begin
    Expr(:call, [name::Symbol, args...], _) => args
    _::Symbol => []
  end
  
  mod = current_module()
  bindings = Dict(c.name => GlobalRef(mod, c.name) for c in sig.terms)
  params = []
  for expr in raw_params
    expr = replace_nullary_constructors(expr, sig)
    expr = replace_symbols(bindings, expr)
    push!(params, expr)
  end
  params
end
function replace_nullary_constructors(expr, sig)
  @match expr begin
    Expr(:call, [name::Symbol], _) => begin
      terms = sig.terms[find(cons -> cons.name == name, sig.terms)]
      @assert length(terms) == 1
      Expr(:call, name, terms[1].typ)
    end
    Expr(:call, [name::Symbol, args...], _) =>
      Expr(:call, name, [replace_nullary_constructors(a,sig) for a in args]...)
    _ => expr
  end
end

""" Generate methods for term generators.

Generators are extra term constructors created automatically for the syntax.
"""
function gen_term_generator(cons::TypeConstructor, sig::Signature)::Expr
  gen_term_constructor(constructor_for_generator(cons), sig;
                       dispatch_type = :generator)
end
function gen_term_generators(sig::Signature)::Vector{Expr}
  [ gen_term_generator(cons, sig) for cons in sig.types ]
end
function constructor_for_generator(cons::TypeConstructor)::TermConstructor
  value_param = :__value__
  params = [ value_param; cons.params ]
  typ = Expr(:call, cons.name, cons.params...)
  context = merge(Context(value_param => :Any), cons.context)
  TermConstructor(cons.name, params, typ, context)
end

# Reflection
############

""" Invoke a term constructor by name in a syntax system.

This method provides reflection for syntax systems. In everyday use the generic
method for the constructor should be called directly, not through this function.
"""
function invoke_term(syntax_module::Module, constructor_name::Symbol, args...)
  signature_module = syntax_module.signature()
  signature = signature_module.class().signature
  syntax_types = Tuple(getfield(syntax_module, cons.name) for cons in signature.types)
  invoke_term(signature_module, syntax_types, constructor_name, args...)
end

""" Name of constructor that created expression.
"""
function constructor_name(expr::BaseExpr)::Symbol
  if head(expr) == :generator
    datatype_name(typeof(expr))
  else
    head(expr)
  end
end

""" Create generator of the same type as the given expression.
"""
function generator_like(expr::BaseExpr, value)::BaseExpr
  invoke_term(
    datatype_module(typeof(expr)),
    datatype_name(typeof(expr)),
    value,
    type_args(expr)...
  )
end

# Functors
##########

""" Functor from GAT expression to GAT instance.

Strictly speaking, we should call these "structure-preserving functors" or,
better, "model homomorphisms of GATs". But this is a category theory library,
so we'll go with the simpler "functor".

A functor is completely determined by its action on the generators. There are
several ways to specify this mapping:

  1. Simply specify a Julia instance type for each doctrine type, using the
     required `types` tuple. For this to work, the generator constructors
     must be defined for the instance types.

  2. Explicitly map each generator term to an instance value, using the
     `generators` dictionary.
  
  3. For each doctrine type (e.g., object and morphism), specify a function
     mapping generator terms of that type to an instance value, using the
     `generator_terms` dictionary.
"""
function functor(types::Tuple, expr::BaseExpr;
                 generators::Associative=Dict(),
                 generator_terms::Associative=Dict())
  # Special case: look up a specific generator.
  if head(expr) == :generator && haskey(generators, expr)
    return generators[expr]
  end
  
  # Special case: look up a type of generator.
  name = constructor_name(expr)
  if head(expr) == :generator && haskey(generator_terms, name)
    return generator_terms[name](expr)
  end
  
  # Otherwise, we need to call a term constructor (possibly for a generator).
  # Recursively evalute the arguments.
  term_args = []
  for arg in args(expr)
    if isa(arg, BaseExpr)
      arg = functor(types, arg; generators=generators,
                    generator_terms=generator_terms)
    end
    push!(term_args, arg)
  end
  
  # Invoke the constructor in the codomain category!
  syntax_module = datatype_module(typeof(expr))
  signature_module = syntax_module.signature()
  invoke_term(signature_module, types, name, term_args...)
end

# Serialization
###############

""" Serialize expression as JSON-able Julia object.

The format is an S-expression encoded as JSON, e.g., "compose(f,g)" is
represented as [:compose, f, g].

Generator values should be symbols, strings, or numbers.
"""
function to_json(expr::BaseExpr)
  [string(constructor_name(expr)); map(to_json, args(expr))]
end
to_json(x::Real) = x
to_json(x) = string(x)

""" Deserialize expression from JSON-able Julia object.

If `symbols` is true (the default), strings are converted to symbols.
"""
function parse_json(syntax_module::Module, sexpr::Vector; kw...)
  name = Symbol(first(sexpr))
  args = [ parse_json(syntax_module, x; kw...) for x in sexpr[2:end] ]
  invoke_term(syntax_module, name, args...)
end
parse_json(::Module, x::String; symbols=true) = symbols ? Symbol(x) : x
parse_json(::Module, x::Real; kw...) = x

# Pretty-print
##############

""" Show the syntax expression as an S-expression.

Cf. the standard library function `Meta.show_sexpr`.
"""
show_sexpr(expr::BaseExpr) = show_sexpr(STDOUT, expr)

function show_sexpr(io::IO, expr::BaseExpr)
  if head(expr) == :generator
    print(io, repr(first(expr)))
  else
    print(io, "(")
    join(io, [string(head(expr));
              [sprint(show_sexpr, arg) for arg in args(expr)]], " ")
    print(io, ")")
  end
end

""" Show the expression in infix notation using Unicode symbols.
"""
show_unicode(expr::BaseExpr) = show_unicode(STDOUT, expr)
show_unicode(io::IO, x::Any; kw...) = show(io, x)

# By default, show in prefix notation.
function show_unicode(io::IO, expr::BaseExpr; kw...)
  print(io, head(expr))
  print(io, "[")
  join(io, [sprint(show_unicode, arg) for arg in args(expr)], ",")
  print(io, "]")
end
show_unicode(io::IO, expr::BaseExpr{:generator}; kw...) = print(io, first(expr))

function show_unicode_infix(io::IO, expr::BaseExpr, op::String; paren::Bool=false)
  show_unicode_paren(io::IO, expr::BaseExpr) = show_unicode(io, expr; paren=true)
  if (paren) print(io, "(") end
  join(io, [sprint(show_unicode_paren, arg) for arg in args(expr)], op)
  if (paren) print(io, ")") end
end

""" Show the expression in infix notation using LaTeX math.

Does *not* include `\$` or `\\[begin|end]{equation}` delimiters.
"""
show_latex(expr::BaseExpr) = show_latex(STDOUT, expr)
show_latex(io::IO, sym::Symbol; kw...) = print(io, sym)
show_latex(io::IO, x::Any; kw...) = show(io, x)

# By default, show in prefix notation.
function show_latex(io::IO, expr::BaseExpr; kw...)
  print(io, "\\mathop{\\mathrm{$(head(expr))}}")
  print(io, "\\left[")
  join(io, [sprint(show_latex, arg) for arg in args(expr)], ",")
  print(io, "\\right]")
end

# Try to be smart about using text or math mode.
function show_latex(io::IO, expr::BaseExpr{:generator}; kw...)
  content = string(first(expr))
  if all(isalpha, content) && length(content) > 1
    print(io, "\\mathrm{$content}")
  else
    print(io, content)
  end
end

function show_latex_infix(io::IO, expr::BaseExpr, op::String; paren::Bool=false, kw...)
  show_latex_paren(io::IO, expr::BaseExpr) = show_latex(io, expr; paren=true, kw...)
  sep = op == " " ? op : " $op "
  if (paren) print(io, "\\left(") end
  join(io, [sprint(show_latex_paren, arg) for arg in args(expr)], sep)
  if (paren) print(io, "\\right)") end
end

function show_latex_script(io::IO, expr::BaseExpr, head::String; super::Bool=false, kw...)
  print(io, head, super ? "^" : "_", "{")
  join(io, [sprint(show_latex, arg) for arg in args(expr)], ",")
  print(io, "}")
end

end
