
use v5.42;
use experimental qw[ class switch ];

use Data::Dumper ();
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
        sprintf '{%s}'
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
class Bool    :isa(Literal) {
    method is_true  {  $self->raw }
    method is_false { !$self->raw }
    method to_string { $self->raw ? 'true' : 'false' }
}

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

class Callable :isa(Term) {
    field $params :param :reader;
    field $body   :param :reader;
    field $env    :param :reader;

    method is_operative   { ... }
    method is_applicative { ... }

    method to_string { ... }
}

class FExpr :isa(Callable) {
    field $name :param :reader;

    method is_operative   { true }
    method is_applicative { false }

    method to_string {
        sprintf '(<fexpr> %s %s)' => $self->params->to_string, $self->body->to_string;
    }
}

class Lambda :isa(Callable) {
    field $name :param :reader;

    method is_operative   { false }
    method is_applicative { true }

    method to_string {
        sprintf '(<lambda> %s %s)' => $self->params->to_string, $self->body->to_string;
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
        my $list = $self->Nil;
        while (@items) {
            $list = $self->Cons( pop @items, $list );
        }
        return $list;
    }

    method Lambda ($p, $b, $e, $name=undef) {
        my $hash = Lambda->hash_of( $p->hash, $b->hash, $e->hash, (defined $name ? $name->hash : ()) );
        $terms{ $hash } //= Lambda->new( params => $p, body => $b, env => $e, name => $name, hash => $hash )
    }

    method FExpr ($p, $b, $e, $name=undef) {
        my $hash = FExpr->hash_of( $p->hash, $b->hash, $e->hash, (defined $name ? $name->hash : ()) );
        $terms{ $hash } //= FExpr->new( params => $p, body => $b, env => $e, name => $name, hash => $hash )
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
                when ('nil') {
                    push $stack[-1]->@*, $alloc->Nil;
                }
                when ('true') {
                    push $stack[-1]->@*, $alloc->True;
                }
                when ('false') {
                    push $stack[-1]->@*, $alloc->False;
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

class Interpreter {
    field $alloc  :param :reader = undef;
    field $parser :param :reader = undef;

    field $tick = 0;

    field @queue;
    field @environment;

    ADJUST {
        $alloc   //= Allocator->new;
        $parser  //= Parser->new( alloc => $alloc );
    }

    method current_env { $environment[-1] }

    method init (%bindings) {
        push @environment => $alloc->Env(%bindings);
        return $self;
    }

    method run ($source) {
        my @exprs = $parser->parse($source);
        my $env   = $environment[-1];
        return $self->execute(\@exprs, $env);
    }

    ## -------------------------------------------------------------------------

    use constant ERROR      => 'ERROR';
    use constant HALT       => 'HALT';
    use constant YIELD      => 'YIELD';

    use constant JUST       => 'JUST';
    use constant DROP       => 'DROP';

    use constant COND       => 'COND';
    use constant BIND       => 'BIND';

    use constant EVAL_EXPR  => 'EVAL_EXPR';
    use constant EVAL_HEAD  => 'EVAL_HEAD';
    use constant EVAL_ARGS  => 'EVAL_ARGS';

    use constant APPLY_EXPR => 'APPLY_EXPR';
    use constant APPLY_CALL => 'APPLY_CALL';

    ## -------------------------------------------------------------------------

    sub Error ($env, $error) { [ ERROR, $env, $error ] }
    sub Halt  ($env)         { [ HALT,  $env ] }
    sub Yield ($env)         { [ YIELD, $env ] }

    sub Drop ($env)         { [ DROP, $env ] }
    sub Just ($env, @stack) { [ JUST, $env, @stack ] }

    # expects Value on stack
    sub Bind ($env, $sym) { [ BIND, $env, $sym ] }

    # expects condition result on stack
    sub Cond ($env, $if_true, @rest) { [ COND, $env, $if_true, @rest ] }

    sub EvalExpr ($env, $expr)          { [ EVAL_EXPR, $env, $expr ] }
    sub EvalHead ($env, $list)          { [ EVAL_HEAD, $env, $list->head, $list->tail ] }
    sub EvalArgs ($env, $args, @evaled) { [ EVAL_ARGS, $env, $args, @evaled ] }

    # expects call on stack
    sub ApplyExpr ($env, $args)        { [ APPLY_EXPR, $env, $args ] }
    sub ApplyCall ($env, $call, @args) { [ APPLY_CALL, $env, $call, @args ] }

    ## -------------------------------------------------------------------------

    method execute ($exprs, $env) {
        push @queue =>
            Halt($env),
            reverse map {
                Drop($env),
                EvalExpr($env, $_)
            } @$exprs;



        while (@queue) {
            $tick++;
            my $next = pop @queue;
            my ($op, $env, @stack) = @$next;
            say sprintf '%05d | %-10s | %6s | %s', $tick, $op, substr($env->hash, 0, 6), join ', ' => map $_->to_string, @stack;
            given ($op) {
                when (JUST) {
                    $queue[-1]->[1] = $env;
                    push $queue[-1]->@* => @stack;
                }
                when (DROP) {
                    $queue[-1]->[1] = $env;
                    # drop the stack ...
                }
                when (BIND) {
                    my ($sym, $term) = @stack;
                    my %local = ($sym->raw, $term);
                    my $local = $alloc->Env( $env, %local );
                    push @queue => Just( $local, $alloc->Nil );
                    say sprintf '%05d |%s|' => $tick, ('-' x 21);
                    say sprintf '%05d | ENV (%s -> %s)' => $tick, substr($env->hash, 0, 6), substr($local->hash, 0, 6);
                    say sprintf '%05d |    +{%s : %s}' => $tick, $_, $local{$_}
                        foreach sort { $a cmp $b } keys %local;
                    say sprintf '%05d |%s|' => $tick, ('-' x 21);
                }
                when (COND) {
                    my $result = pop @stack;
                    if ($result isa Bool && $result->is_true) {
                        my $action = shift @stack;
                        push @queue => EvalExpr( $env, $action );
                    } else {
                        shift @stack; # drop the if-true action
                        if (@stack) {
                            my ($next, @rest) = @stack;
                            push @queue =>
                                Cond( $env, $next->second, @rest ),
                                EvalExpr( $env, $next->first );
                        }
                    }
                }
                when (HALT) {
                    return @stack;
                }
                when (ERROR) {
                    die "ERROR! - ", map $_->to_string, @stack
                }
                default {
                    push @queue => $self->step( $next );
                }
            }
        }
    }

    method eval ($expr, $env) {
        given (blessed $expr) {
            when ('Cons') {
                return EvalHead($env, $expr);
            }
            when ('Sym') {
                my $val = $env->lookup($expr);
                return defined $val
                    ? Just($env, $val)
                    : Error($env, $alloc->Sym("Unable to find $expr in Env"))
            }
            default {
                return Just($env, $expr)
            }
        }
    }

    method step ($step) {
        my ($op, $env, @rest) = $step->@*;
        given ($op) {
            when (EVAL_EXPR) {
                my ($expr) = @rest;
                return $self->eval( $expr, $env );
            }
            when (EVAL_HEAD) {
                my ($head, $rest) = @rest;
                return ApplyExpr( $env, $rest ),
                       $self->eval( $head, $env );
            }
            when (EVAL_ARGS) {
                my ($expr, @stack) = @rest;
                if ($expr->is_nil) {
                    return Just( $env, @stack );
                }
                else {
                    return EvalArgs( $env, $expr->tail, @stack ),
                           $self->eval( $expr->head, $env );
                }
            }
            when (APPLY_EXPR) {
                my ($args, $call) = @rest;
                if ($call->is_applicative) {
                    return ApplyCall( $env, $call ), EvalArgs( $env, $args );
                } else {
                    my @args = ($env);
                    until ($args->is_nil) {
                        push @args => $args->head;
                        $args = $args->tail;
                    }
                    return ApplyCall( $env, $call, @args );
                }
            }
            when (APPLY_CALL) {
                my ($call, @args) = @rest;
                given (blessed $call) {
                    when ('Procedure') {
                        if ($call->is_operative) {
                            return $call->body->( @args );
                        } else {
                            return Just( $env, $call->body->( @args ) );
                        }
                    }
                    when (/^(Lambda|FExpr)$/) {
                        my %local;
                        if (defined $call->name) {
                            $local{ $call->name->raw } = $call;
                        }
                        my $params = $call->params;
                        until ($params->is_nil) {
                            $local{ $params->head->raw } = shift @args;
                            $params = $params->tail;
                        }
                        my $local = $alloc->Env( $call->env, %local );
                        say sprintf '%05d |%s|' => $tick, ('-' x 21);
                        say sprintf '%05d | ENV (%s -> %s)' => $tick, substr($env->hash, 0, 6), substr($local->hash, 0, 6);
                        say sprintf '%05d |    +{%s : %s}' => $tick, $_, $local{$_}
                            foreach sort { $a cmp $b } keys %local;
                        say sprintf '%05d |%s|' => $tick, ('-' x 21);
                        return EvalExpr( $local, $call->body );
                    }
                    default {
                        die $call;
                    }
                }
            }
            default {
                die "ERROR! - Uurecognized op ${op}";
            }
        }
    }
}

## -----------------------------------------------------------------------------

my $i = Interpreter->new;
my $a = $i->alloc;

my sub add ($n, $m) { $a->Num( $n->raw + $m->raw ) }
my sub sub ($n, $m) { $a->Num( $n->raw - $m->raw ) }
my sub mul ($n, $m) { $a->Num( $n->raw * $m->raw ) }
my sub div ($n, $m) { $a->Num( $n->raw / $m->raw ) }
my sub mod ($n, $m) { $a->Num( $n->raw % $m->raw ) }

my sub num_eq ($n, $m) { $n->raw == $m->raw ? $a->True : $a->False }
my sub num_ne ($n, $m) { $n->raw != $m->raw ? $a->True : $a->False }
my sub num_gt ($n, $m) { $n->raw >  $m->raw ? $a->True : $a->False }
my sub num_lt ($n, $m) { $n->raw <  $m->raw ? $a->True : $a->False }
my sub num_ge ($n, $m) { $n->raw >= $m->raw ? $a->True : $a->False }
my sub num_le ($n, $m) { $n->raw <= $m->raw ? $a->True : $a->False }

my sub eqp ($n, $m) { $n->hash eq $m->hash ? $a->True : $a->False }

my sub atomp ($n) { $n isa Literal  ? $a->True : $a->False }
my sub nilp  ($n) { $n isa Nil      ? $a->True : $a->False }

my sub car ($l) { $l->head }
my sub cdr ($l) { $l->tail }

my sub caar  ($l) { $l->head->head }
my sub cadr  ($l) { $l->head->tail }
my sub cdar  ($l) { $l->tail->head }
my sub cadar ($l) { $l->head->tail->head }
my sub caddr ($l) { $l->head->tail->tail }
my sub cddar ($l) { $l->tail->tail->head }

my sub cons ($h, $t) { $a->Cons( $h, $t ) }
my sub list (@items) { $a->List(@items) }

my sub quote  ($E, $l)           { Interpreter::Just( $E, $l ) }
my sub lambda ($E, $p, $b)       { Interpreter::Just( $E, $a->Lambda( $p, $b, $E ) ) }
my sub defun  ($E, $sym, $p, $b) {
    return Interpreter::Bind( $E, $sym ),
           Interpreter::EvalExpr( $E, $a->Lambda( $p, $b, $E, $sym ) );
}

my sub cond ($E, $first, @rest) {
    my ($cond, $if_true) = $first->uncons;
    return Interpreter::Cond( $E, $if_true, @rest ),
           Interpreter::EvalExpr( $E, $cond )
}

$i->init(
    'lambda' => $a->Procedure( \&lambda, is_operative => true ),
    'quote'  => $a->Procedure( \&quote,  is_operative => true ),
    'defun'  => $a->Procedure( \&defun, is_operative => true ),
    'cond'   => $a->Procedure( \&cond,   is_operative => true ),
    # predicates
    'atom?'  => $a->Procedure( \&atomp, is_applicative => true ),
    'nil?'   => $a->Procedure( \&nilp,  is_applicative => true ),
    'eq?'    => $a->Procedure( \&eqp,   is_applicative => true ),
    # list constructors
    'list'   => $a->Procedure( \&list,  is_applicative => true ),
    'cons'   => $a->Procedure( \&cons,  is_applicative => true ),
    # list accessors
    'car'    => $a->Procedure( \&car,   is_applicative => true ),
    'cdr'    => $a->Procedure( \&cdr,   is_applicative => true ),
    # ... all of them
    'caar'   => $a->Procedure( \&caar,  is_applicative => true ),
    'cadr'   => $a->Procedure( \&cadr,  is_applicative => true ),
    'cdar'   => $a->Procedure( \&cdar,  is_applicative => true ),
    'cadar'  => $a->Procedure( \&cadar, is_applicative => true ),
    'caddr'  => $a->Procedure( \&caddr, is_applicative => true ),
    'cddar'  => $a->Procedure( \&cddar, is_applicative => true ),
    # maths
    '+' => $a->Procedure( \&add, is_applicative => true ),
    '-' => $a->Procedure( \&sub, is_applicative => true ),
    '*' => $a->Procedure( \&mul, is_applicative => true ),
    '/' => $a->Procedure( \&div, is_applicative => true ),
    '%' => $a->Procedure( \&mod, is_applicative => true ),
    # numeric equality and comparisons
    '==' => $a->Procedure( \&num_eq, is_applicative => true ),
    '!=' => $a->Procedure( \&num_ne, is_applicative => true ),
    '>'  => $a->Procedure( \&num_gt, is_applicative => true ),
    '<'  => $a->Procedure( \&num_lt, is_applicative => true ),
    '>=' => $a->Procedure( \&num_ge, is_applicative => true ),
    '<=' => $a->Procedure( \&num_le, is_applicative => true ),
);


say $i->run(q[

    (defun fact (n)
        (cond ((== n 0) 1)
               (true    (* n (fact (- n 1))))))

    (fact 10)

]);


## -----------------------------------------------------------------------------


__END__



(defun fib (n)
    (cond
        (
            (< n 2)
            n
        )
        (
            true
            (+ (fib (- n 2)) (fib (- n 1)))
        )
    )
)

    (fib 2)
