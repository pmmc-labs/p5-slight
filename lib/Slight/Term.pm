use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

class Term {
    field $index :param :reader;
    field $data  :param :reader;
    method is_nil { false }
    method equal_to ($o) { $index->hash eq $o->index->hash }
    method short_hash { substr($index->hash, 0, 6) }
}

class Tag     :isa(Term) { method ident { $self->data->[0] } }
class Sym     :isa(Term) { method ident { $self->data->[0] } }
class Str     :isa(Term) { method value { $self->data->[0] } }
class Num     :isa(Term) { method value { $self->data->[0] } }
class Bool    :isa(Term) {
    method is_true  { $self->data->[0] eq '#t' }
    method is_false { $self->data->[0] eq '#f' }
}
class Nil     :isa(Term) { method is_nil { true } }
class Cons    :isa(Term) {} # head, tail
class Pair    :isa(Cons) {} # Pair is a cons where tail is not a list
class Env     :isa(Cons) {} # Env is a list of pairs
class Binding :isa(Cons) {} # Pair of Symbol + Term

# compile-time version (w/ out env)
class Partial :isa(Term) { # params, body, name?
    method has_name { defined $self->data->[2] }
}

# runtime-time version (w/ captured runtime env)
class Lambda  :isa(Term) { # params, body, env, name?
    method has_name { defined $self->data->[3] }
}

class Condition :isa(Term) {} # condition, if-true, if-false
class Builtin   :isa(Term) {} # name, CODE
