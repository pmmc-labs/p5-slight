
use v5.42;
use experimental qw[ class switch ];

use Carp         ();
use Digest::MD5  ();
use Scalar::Util ();
use Sub::Util    ();

## -----------------------------------------------------------------------------

class Term {
    use overload '""' => 'to_string';
    field $hash :param :reader;

    method is_nil      { false }
    method is_callable { false }

    method to_string { __CLASS__ }

    sub hash_of ($class, @args) {
        Digest::MD5::md5_hex($class, @args);
    }
}

## -----------------------------------------------------------------------------

class Env :isa(Term) {
    field $parent :param :reader = undef;
    field $local  :param :reader;

    method lookup ($sym) {
        $local->{ $sym->raw }
            // (defined $parent
                ? $parent->lookup($sym)
                : die "Could not find symbol(${sym}) in env");
    }

    method to_string {
        sprintf '(env %s)'
            => (join ', ' =>
                map  { sprintf '%s: %s' => $_, $local->{$_}->to_string }
                grep { !($local->{$_} isa Procedure) }
                sort { $a cmp $b }
                keys %$local)
    }
}

## -----------------------------------------------------------------------------

class Literal :isa(Term) {
    field $raw :param :reader;

    method to_string { "${raw}" }
}
class Num     :isa(Literal) {}
class Sym     :isa(Literal) {}
class Bool    :isa(Literal) {}

class Pair :isa(Term) {
    field $first  :param :reader;
    field $second :param :reader;

    method to_string {
        sprintf '(%s . %s)' => $first->to_string, $second->to_string;
    }
}

class List :isa(Term) {}
class Nil  :isa(List) {
    method is_nil { true }
    method to_string { '()' }
}
class Cons :isa(List) {
    field $head :param :reader;
    field $tail :param :reader;

    method to_string {
        sprintf '(%s %s)' => $head->to_string, $tail->to_string;
    }
}

class Callable :isa(Term) {
    field $params :param :reader;
    field $body   :param :reader;
    field $env    :param :reader;

    method to_string { ... }
}

class FExpr :isa(Callable) {
    method to_string {
        sprintf '(fexpr %s %s)' => $self->params->to_string, $self->body->to_string;
    }
}

class Lambda :isa(Callable) {
    method to_string {
        sprintf '(lambda %s %s)' => $self->params->to_string, $self->body->to_string;
    }
}

class Procedure :isa(Term) {
    field $body           :param :reader;
    field $is_operative   :param :reader = false;
    field $is_applicative :param :reader = false;

    method to_string {
        sprintf '#<%s>' => Sub::Util::subname($self->body);
    }
}

## -----------------------------------------------------------------------------

class Allocator {
    field %terms;

    field $Nil;
    field $True;
    field $False;

    ADJUST {
        $Nil   = Nil->new( hash => Nil->hash_of('nil') );
        $True  = Bool->new( raw => true,  hash => Bool->hash_of('true') );
        $False = Bool->new( raw => false, hash => Bool->hash_of('false') );
    }

    method Nil   { $Nil }
    method True  { $True }
    method False { $False }

    method Num ($n) {
        my $hash = Num->hash_of($n);
        $terms{ $hash } //= Num->new( raw => $n, hash => $hash )
    }

    method Sym ($s) {
        my $hash = Sym->hash_of($s);
        $terms{ $hash } //= Sym->new( raw => $s, hash => $hash )
    }

    method Pair ($f, $s) {
        my $hash = Pair->hash_of( $f->hash, $s->hash );
        $terms{ $hash } //= Pair->new( first => $f, second => $s, hash => $hash )
    }

    method Cons ($h, $t) {
        my $hash = Cons->hash_of( $h->hash, $t->hash );
        $terms{ $hash } //= Cons->new( head => $h, tail => $t, hash => $hash )
    }

    method List (@items) {
        #say ">> LIST ", join ', ' => map $_->to_string, @items;
        my $list = $self->Nil;
        while (@items) {
            #say "... LIST! ", $list->to_string;
            $list = $self->Cons( pop @items, $list );
        }
        #say "<< LIST ", $list->to_string;
        return $list;
    }

    method Lambda ($p, $b, $e) {
        my $hash = Lambda->hash_of( $p->hash, $b->hash, $e->hash );
        $terms{ $hash } //= Lambda->new( params => $p, body => $b, env => $e, hash => $hash )
    }

    method FExpr ($p, $b, $e) {
        my $hash = FExpr->hash_of( $p->hash, $b->hash, $e->hash );
        $terms{ $hash } //= FExpr->new( params => $p, body => $b, env => $e, hash => $hash )
    }

    method Procedure ($b, %opts) {
        my $hash = Procedure->hash_of( Sub::Util::subname($b) );
        $terms{ $hash } //= Procedure->new( body => $b, hash => $hash, %opts )
    }

    method Env (@args) {
        my $parent;
        if (blessed $args[0] && $args[0] isa Env) {
            $parent = shift @args;
        }
        my %local = @args;
        my $hash = Env->hash_of(
            (defined $parent ? $parent->hash : '*ROOT-ENV*'),
            map { $_, $local{$_}->hash  } sort { $a cmp $b } keys %local
        );
        $terms{ $hash } //= Env->new( parent => $parent, local => \%local, hash => $hash )
    }
}

## -----------------------------------------------------------------------------

class Interpreter {
    field $alloc :param :reader;

    field $current_env :reader;
    field @env_history :reader;

    ADJUST {
        $current_env = $alloc->Env();
    }

    method bind (%bindings) {
        push @env_history => $current_env->hash;
        $current_env = $alloc->Env( $current_env, %bindings )
    }

    method run (@exprs) {

        my @statements;
        while (@exprs) {
            my $expr = shift @exprs;
            push @statements => $self->eval( $expr, $current_env );
            #given ($statements[-1]) {}
        }

        push @env_history => $current_env->hash;
        return pop @statements;
    }

    method eval ($expr, $env) {
        say '> EVAL ', $expr->to_string;
        given (blessed $expr) {
            when ('Sym') {
                return $env->lookup($expr)
            }
            when ('Cons') {
                return $self->apply(
                    $self->eval($expr->head, $env),
                    $expr->tail,
                    $env
                )
            }
            default {
                return $expr
            }
        }
    }

    method apply ($call, $args, $env) {
        say '> APPLY ', $call->to_string, ' w/ @ARGS ', $args->to_string;
        given (blessed $call) {
            when ('FExpr') {
                my %params;
                my $arg   = $args;
                my $param = $call->params;
                until ($param->is_nil && $arg->is_nil) {
                    $params{ $param->head->raw } = $arg->head;
                    $param = $param->tail;
                    $arg   = $arg->tail;
                }
                $self->eval( $call->body, $alloc->Env( $env, %params ) )
            }
            when ('Lambda') {
                my %params;
                my $arg   = $args;
                my $param = $call->params;
                until ($param->is_nil && $arg->is_nil) {
                    #say '>> PARAM >> ', $param->head;
                    #say '>>   ARG >> ', $arg->head;
                    $params{ $param->head->raw } = $self->eval( $arg->head, $env );
                    $param = $param->tail;
                    $arg   = $arg->tail;
                }
                say '  ->& ', $call->to_string, ' w/  %ARGS ', join ', ' => map { sprintf '%s: %s' => $_, $params{$_}->to_string } keys %params;
                $self->eval( $call->body, $alloc->Env( $env, %params ) )
            }
            when ('Procedure') {
                my @args;
                push @args => $env if $call->is_operative;
                while (!$args->is_nil) {
                    push @args => $call->is_applicative ? $self->eval($args->head, $env) : $args->head;
                    $args = $args->tail;
                }
                say '  ->& ', $call->to_string, ' w/ @ARGS ', join ', ' => map $_->to_string, @args;
                $call->body->( @args );
            }
            default { Carp::confess "WTF is a $call doing here!" }
        }
    }
}

## -----------------------------------------------------------------------------


class Parser {
    field $alloc :param :reader;

    field @stack;

    ADJUST {
        push @stack => +[];
    }

    method tokenizer ($source) {
        grep !/^\s*$/, split /(\(|\)|\s)/ => $source;
    }

    method parse ($source) {
        my @tokens = $self->tokenizer($source);
        while (@tokens) {
            my $token = shift @tokens;
            given ($token) {
                when ('(') {
                    push @stack => +[];
                }
                when (')') {
                    my $list = pop @stack;
                    push $stack[-1]->@*, $alloc->List($list->@*);
                }
                when (/^\d+$/) {
                    push $stack[-1]->@*, $alloc->Num($token);
                }
                default {
                    push $stack[-1]->@*, $alloc->Sym($token);
                }
            }
        }
        return $stack[-1]->@*;
    }

}

## -----------------------------------------------------------------------------

my $a = Allocator->new;
my $p = Parser->new( alloc => $a );
my $i = Interpreter->new( alloc => $a );

my sub add ($n, $m) { $a->Num( $n->raw + $m->raw ) }
my sub sub ($n, $m) { $a->Num( $n->raw - $m->raw ) }
my sub mul ($n, $m) { $a->Num( $n->raw * $m->raw ) }
my sub div ($n, $m) { $a->Num( $n->raw / $m->raw ) }
my sub mod ($n, $m) { $a->Num( $n->raw % $m->raw ) }

my sub eqp ($n, $m) { $n->hash eq $m->hash ? $a->True : $a->False }

my sub lambda ($e, $p, $b) { $a->Lambda($p, $b, $e) }

$i->bind(
    'eq?' => $a->Procedure( \&eqp, is_applicative => true ),
    'add' => $a->Procedure( \&add, is_applicative => true ),
    'sub' => $a->Procedure( \&sub, is_applicative => true ),
    'mul' => $a->Procedure( \&mul, is_applicative => true ),
    'div' => $a->Procedure( \&div, is_applicative => true ),
    'mod' => $a->Procedure( \&mod, is_applicative => true ),

    'lambda' => $a->Procedure( \&lambda, is_operative => true ),
);


say $i->run( $p->parse(q[

    ((lambda (n m) (add n m)) 10 20)

    ((lambda (n m) (mul n m)) 10 20)

]));

say $_ foreach $i->env_history;

## -----------------------------------------------------------------------------



