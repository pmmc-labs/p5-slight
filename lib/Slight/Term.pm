
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Digest::MD5 ();

## -----------------------------------------------------------------------------
## Slight::Terms
## -----------------------------------------------------------------------------

class Slight::Term {
    use overload '""' => 'to_string';
    field $hash :param :reader;

    method is_nil      { false }
    method is_callable { false }

    method to_string { __CLASS__ }

    sub hash_of ($class, @args) {
        Digest::MD5::md5_hex(join ':' => $class, @args);
    }
}

## ------------------------------------
## Environment
## ------------------------------------

class Slight::Term::Env :isa(Slight::Term) {
    field $parent :param :reader = undef;
    field $local  :param :reader;

    method lookup ($sym) {
        if (exists $local->{ $sym->raw }) {
            return $local->{ $sym->raw };
        } else {
            if (defined $parent) {
                return $parent->lookup($sym);
            } else {
                die "Could not find symbol(${sym}) in env";
            }
        }
    }

    method to_string {
        sprintf '%s:{%s}'
            => substr($self->hash, 0, 6),
               (join ', ' =>
                map  { sprintf '%s: %s' => $_, $local->{$_}->to_string }
                grep { !($local->{$_} isa Slight::Term::Procedure) }
                sort { $a cmp $b }
                keys %$local)
    }
}

## ------------------------------------
## Literal Values
## ------------------------------------

class Slight::Term::Literal :isa(Slight::Term) {
    field $raw :param :reader;

    method to_string { "${raw}" }
}
class Slight::Term::Num :isa(Slight::Term::Literal) {}
class Slight::Term::Sym :isa(Slight::Term::Literal) {}
class Slight::Term::Str :isa(Slight::Term::Literal) {
    method to_string { sprintf '"%s"' => $self->raw }
}

class Slight::Term::Bool :isa(Slight::Term::Literal) {
    method is_true  {  $self->raw }
    method is_false { !$self->raw }
    method to_string { $self->raw ? 'true' : 'false' }
}

## ------------------------------------
## Containers
## ------------------------------------

class Slight::Term::Pair :isa(Slight::Term) {
    field $first  :param :reader;
    field $second :param :reader;

    method to_string {
        sprintf '(%s . %s)' => $first->to_string, $second->to_string;
    }
}

class Slight::Term::List :isa(Slight::Term) {}
class Slight::Term::Nil  :isa(Slight::Term::List) {
    method is_nil { true }
    method to_string { '()' }
}
class Slight::Term::Cons :isa(Slight::Term::List) {
    field $head :param :reader;
    field $tail :param :reader;

    method uncons {
        my @list;
        my $l = $self;
        until ($l->is_nil) {
            push @list => $l->head;
            $l = $l->tail;
        }
        return @list;
    }

    method first  { $head }
    method second { $tail->head }

    method to_string {
        sprintf '(%s)' => join ' ' => map $_->to_string, $self->uncons;
    }
}

## ------------------------------------
## Callables
## ------------------------------------

class Slight::Term::Callable :isa(Slight::Term) {
    field $params :param :reader;
    field $body   :param :reader;
    field $env    :param :reader;

    method is_operative   { ... }
    method is_applicative { ... }

    method to_string { ... }
}

class Slight::Term::FExpr :isa(Slight::Term::Callable) {
    field $name :param :reader;

    method is_operative   { true }
    method is_applicative { false }

    method to_string {
        sprintf '(<fexpr> %s %s)' => $self->params->to_string, $self->body->to_string;
    }
}

class Slight::Term::Lambda :isa(Slight::Term::Callable) {
    field $name :param :reader;

    method is_operative   { false }
    method is_applicative { true }

    method to_string {
        sprintf '(<lambda> %s %s)' => $self->params->to_string, $self->body->to_string;
    }
}

class Slight::Term::Procedure :isa(Slight::Term) {
    field $name           :param :reader;
    field $body           :param :reader;
    field $is_operative   :param :reader = false;
    field $is_applicative :param :reader = false;

    method to_string {
        sprintf '#<%s>' => $name->to_string;
    }
}

