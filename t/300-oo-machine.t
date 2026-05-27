
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;

## -----------------------------------------------------------------------------

class Kontinue {
    use overload '""' => 'to_string';
    field $env   :param :reader;
    field @stack :reader;

    method STEP ($ctx) { ... }

    method THREAD ($e) {
        $env = $e;
        $self;
    }

    method PUSH (@items) {
        push @stack => @items;
        $self;
    }

    method to_string {
        sprintf '%s[%s]@%s' =>
            __CLASS__,
            substr($env->hash, 0, 6),
            (scalar @stack ? ('( '.(join ', ' => @stack).' )') : '()');
    }
}

class Halt  :isa(Kontinue) {}
class Yield :isa(Kontinue) {}

class Error :isa(Kontinue) {
    field $error :param :reader;
}

class Just :isa(Kontinue) {
    method STEP ($ctx) {
        $ctx->thread_computation( $self->env, $self->stack );
    }
}

class Drop :isa(Kontinue) {
    method STEP ($ctx) {
        $ctx->thread_computation( $self->env );
    }
}

class Eval::Expr :isa(Kontinue) {
    field $expr :param :reader;

    method STEP ($ctx) {
        given (blessed $expr) {
            when ('Slight::Term::Sym') {
                return Just->new( env => $self->env )->PUSH(
                    $self->env->lookup( $expr )
                );
            }
            when ('Slight::Term::Cons') {
                return Eval::Head->new(
                    env  => $self->env,
                    head => $expr->head,
                    rest => $expr->tail,
                );
            }
            default {
                return Just->new( env => $self->env )->PUSH(
                    $expr
                );
            }
        }
    }
}

class Eval::Head :isa(Kontinue) {
    field $head :param :reader;
    field $rest :param :reader;

    method STEP ($ctx) {
        return Apply::Expr->new( env => $self->env, args => $rest ),
                Eval::Expr->new( env => $self->env, expr => $head );
    }
}

class Eval::Rest :isa(Kontinue) {
    field $rest :param :reader;

    method STEP ($ctx) {
        if ($rest->is_nil) {
            return Just->new( env => $self->env )->PUSH( $self->stack );
        } else {
            return Eval::Rest->new( env => $self->env, rest => $rest->tail )->PUSH( $self->stack ),
                    Eval::Expr->new( env => $self->env, expr => $rest->head );
        }
    }
}

class Apply::Expr :isa(Kontinue) {
    field $args :param :reader;

    method STEP ($ctx) {
        my ($call) = $self->stack;
        if ($call->is_applicative) {
            return Apply::Call->new( env => $self->env, call => $call ),
                    Eval::Rest->new( env => $self->env, rest => $args );
        } else {
            return Apply::Call->new( env => $self->env, call => $call )->PUSH( $self->env, $self->args->uncons );
        }
    }
}

class Apply::Call :isa(Kontinue) {
    field $call :param :reader;

    method STEP ($ctx) {
        my @args = $self->stack;
        given (blessed $call) {
            when ('Slight::Term::Procedure') {
                if ($call->is_applicative) {
                    return Just->new( env => $self->env )->PUSH( $call->body->( @args ) );
                } else {
                    return $call->body->( @args );
                }
            }
            when ('Slight::Term::Lambda') {
                my %local;
                my @params = $call->params->uncons;
                while (@params) {
                    my $param = shift @params;
                    $local{ $param->raw } = shift @args;
                }
                if (my $rec = $call->name) {
                    $local{ $rec->raw } = $call;
                }
                my $local = $ctx->derive_env( $call->env, %local );
                return Scope::Leave->new( env => $self->env ),
                         Eval::Expr->new( env => $local, expr => $call->body ),
                       Scope::Enter->new( env => $local );
            }
            default {
                die "Unknown callable type: $call";
            }
        }
    }
}

class Bind :isa(Kontinue) {
    field $name :param :reader;

    method STEP ($ctx) {
        my ($value) = $self->stack;
        return Drop->new( env => $ctx->bind_variable( $self->env, $name, $value ) )
    }
}

class Cond :isa(Kontinue) {
    field $if_true   :param :reader;
    field $if_false  :param :reader;

    method STEP ($ctx) {
        my ($condition) = $self->stack;
        if ($condition isa Slight::Term::Bool && $condition->is_true) {
            return Eval::Expr->new( env => $self->env, expr => $if_true );
        } else {
            return Eval::Expr->new( env => $self->env, expr => $if_false );
        }
    }
}

class Scope::Enter :isa(Kontinue) {
    method STEP ($ctx) {
        return ();
    }
}

class Scope::Leave :isa(Kontinue) {
    field $orig_env :reader;

    ADJUST { $orig_env = $self->env }

    method STEP ($ctx) {
        $ctx->thread_computation( $orig_env, $self->stack );
    }
}

## -----------------------------------------------------------------------------

class Context {
    field $pid   :param :reader;
    field $alloc :param :reader;
    field @queue :reader;
    field @trace :reader;

    method derive_env ($env, %local) {
        return $alloc->Env( $env, %local );
    }

    method bind_variable ($env, $sym, $value) {
        return $alloc->Env( $env, $sym->raw, $value );
    }

    method thread_computation ($env, @stack) {
        my $tos = $queue[-1];
        $tos->THREAD( $env );
        $tos->PUSH( @stack );
        return ();
    }

    method enqueue (@q) { push @queue => @q }

    method run_until_host {
        while (@queue) {
            #say '-' x 80;
            #say sprintf 'QUEUE[%03d]: %s' => $pid, join ', ' => @queue;
            my $next = pop @queue;
            unshift @trace => $next;
            #say '=' x 80;
            say sprintf ' STEP[%03d]: %s' => $pid, $next;
            given (blessed $next) {
                when ('Halt') {
                    return $next;
                }
                when ('Yield') {
                    return $next;
                }
                default {
                    push @queue => $next->STEP( $self );
                }
            }
        }
        say '!' x 80;
    }
}

## -----------------------------------------------------------------------------

class System {
    field $alloc    :reader :param = undef;
    field $root_env :reader :param = undef;
    field @running  :reader;
    field @halted   :reader;

    ADJUST {
        $alloc    //= Slight::Allocator->new;
        $root_env //= $self->initialize_root_environment;
    }

    our $PID_SEQ = 0;

    method spawn_context ($exprs) {
        my $ctx = Context->new( pid => ++$PID_SEQ, alloc => $alloc );
        $ctx->enqueue( @$exprs );
        push @running => $ctx;
        return $ctx;
    }

    method run {
        while (@running) {
            my $ctx  = shift @running;
            my $kont = $ctx->run_until_host;
            if ($kont isa Halt) {
                push @halted => $ctx;
            } else {
                push @running => $ctx;
            }
        }
        return @halted;
    }

    method compile ($src) {
        my @exprs = Slight::Parser->new( alloc => $alloc )->parse( $src );
        return +[
            Halt->new( env => $root_env ),
            (reverse map {
                Drop->new( env => $root_env ),
                Eval::Expr->new( env => $root_env, expr => $_ )
            } @exprs),
        ];
    }

    method initialize_root_environment {
        my sub add ($n, $m) { $alloc->Num( $n->raw + $m->raw ) }
        my sub sub ($n, $m) { $alloc->Num( $n->raw - $m->raw ) }
        my sub mul ($n, $m) { $alloc->Num( $n->raw * $m->raw ) }
        my sub div ($n, $m) { $alloc->Num( $n->raw / $m->raw ) }
        my sub mod ($n, $m) { $alloc->Num( $n->raw % $m->raw ) }

        my sub num_eq ($n, $m) { $n->raw == $m->raw ? $alloc->True : $alloc->False }
        my sub num_ne ($n, $m) { $n->raw != $m->raw ? $alloc->True : $alloc->False }
        my sub num_gt ($n, $m) { $n->raw >  $m->raw ? $alloc->True : $alloc->False }
        my sub num_lt ($n, $m) { $n->raw <  $m->raw ? $alloc->True : $alloc->False }
        my sub num_ge ($n, $m) { $n->raw >= $m->raw ? $alloc->True : $alloc->False }
        my sub num_le ($n, $m) { $n->raw <= $m->raw ? $alloc->True : $alloc->False }

        my sub concat ($n, $m) { $alloc->Str( $n->raw . $m->raw ) }

        my sub eqp ($n, $m) { $n->hash eq $m->hash ? $alloc->True : $alloc->False }

        my sub atomp ($n) { $n isa Slight::Term::Literal  ? $alloc->True : $alloc->False }
        my sub nilp  ($n) { $n isa Slight::Term::Nil      ? $alloc->True : $alloc->False }

        my sub car ($l) { $l->head }
        my sub cdr ($l) { $l->tail }

        my sub caar  ($l) { $l->head->head }
        my sub cadr  ($l) { $l->head->tail }
        my sub cdar  ($l) { $l->tail->head }
        my sub cadar ($l) { $l->head->tail->head }
        my sub caddr ($l) { $l->head->tail->tail }
        my sub cddar ($l) { $l->tail->tail->head }

        my sub cons ($h, $t) { $alloc->Cons( $h, $t ) }
        my sub list (@items) { $alloc->List( @items ) }

        my sub lambda ($E, $p, $b) {
            Just->new( env => $E )->PUSH( $alloc->Lambda( $p, $b, $E ) )
        }

        my sub quote  ($E, @terms) {
            Just->new( env => $E )->PUSH( scalar @terms == 1 ? $terms[0] : $alloc->List(@terms) )
        }

        my sub defun  ($E, $sym, $p, $b) {
            return Bind->new( env => $E, name => $sym ),
                   Eval::Expr->new( env => $E, expr => $alloc->Lambda( $p, $b, $E, $sym ) );
        }

        my sub let  ($E, $sym, $value) {
            return Bind->new( env => $E, name => $sym ),
                   Eval::Expr->new( env => $E, expr => $value );
        }

        my sub yield ($E, $expr) {
            return Eval::Expr->new( env => $E, expr => $expr ),
                   Yield->new( env => $E );
        }

        my sub _if ($E, $cond, $if_true, $if_false) {
            return Cond->new( env => $E, if_true => $if_true, if_false => $if_false ),
                   Eval::Expr->new( env => $E, expr => $cond );
        }

        my sub _do ($E, @exprs) {
            my @progn = reverse map {
                Drop->new( env => $E ),
                Eval::Expr->new( env => $E, expr => $_ )
            } @exprs;
            pop @progn;
            return @progn;
        }

        $alloc->Env(
            # special forms
            'lambda' => $alloc->Procedure( $alloc->Sym('lambda' ), \&lambda, is_operative => true ),
            'quote'  => $alloc->Procedure( $alloc->Sym('quote'  ), \&quote,  is_operative => true ),
            'defun'  => $alloc->Procedure( $alloc->Sym('defun'  ), \&defun,  is_operative => true ),
            'let'    => $alloc->Procedure( $alloc->Sym('let'    ), \&let,    is_operative => true ),
            'if'     => $alloc->Procedure( $alloc->Sym('if'     ), \&_if,    is_operative => true ),
            'do'     => $alloc->Procedure( $alloc->Sym('do'     ), \&_do,    is_operative => true ),
            'yield'  => $alloc->Procedure( $alloc->Sym('yield'  ), \&yield,  is_operative => true ),

            # predicates
            'atom?'  => $alloc->Procedure( $alloc->Sym('atom?'  ), \&atomp, is_applicative => true ),
            'nil?'   => $alloc->Procedure( $alloc->Sym('nil?'   ), \&nilp,  is_applicative => true ),
            'eq?'    => $alloc->Procedure( $alloc->Sym('eq?'    ), \&eqp,   is_applicative => true ),

            # lists
            'list'   => $alloc->Procedure( $alloc->Sym('list'   ), \&list,  is_applicative => true ),
            'cons'   => $alloc->Procedure( $alloc->Sym('cons'   ), \&cons,  is_applicative => true ),
            'car'    => $alloc->Procedure( $alloc->Sym('car'    ), \&car,   is_applicative => true ),
            'cdr'    => $alloc->Procedure( $alloc->Sym('cdr'    ), \&cdr,   is_applicative => true ),
            'caar'   => $alloc->Procedure( $alloc->Sym('caar'   ), \&caar,  is_applicative => true ),
            'cadr'   => $alloc->Procedure( $alloc->Sym('cadr'   ), \&cadr,  is_applicative => true ),
            'cdar'   => $alloc->Procedure( $alloc->Sym('cdar'   ), \&cdar,  is_applicative => true ),
            'cadar'  => $alloc->Procedure( $alloc->Sym('cadar'  ), \&cadar, is_applicative => true ),
            'caddr'  => $alloc->Procedure( $alloc->Sym('caddr'  ), \&caddr, is_applicative => true ),
            'cddar'  => $alloc->Procedure( $alloc->Sym('cddar'  ), \&cddar, is_applicative => true ),

            # ops for strings
            '~' => $alloc->Procedure( $alloc->Sym('~'), \&concat, is_applicative => true ),

            # maths for numbers
            '+' => $alloc->Procedure( $alloc->Sym('+'), \&add, is_applicative => true ),
            '-' => $alloc->Procedure( $alloc->Sym('-'), \&sub, is_applicative => true ),
            '*' => $alloc->Procedure( $alloc->Sym('*'), \&mul, is_applicative => true ),
            '/' => $alloc->Procedure( $alloc->Sym('/'), \&div, is_applicative => true ),
            '%' => $alloc->Procedure( $alloc->Sym('%'), \&mod, is_applicative => true ),

            # eq/ordering for numbers
            '==' => $alloc->Procedure( $alloc->Sym('=='), \&num_eq, is_applicative => true ),
            '!=' => $alloc->Procedure( $alloc->Sym('!='), \&num_ne, is_applicative => true ),
            '>'  => $alloc->Procedure( $alloc->Sym('>' ), \&num_gt, is_applicative => true ),
            '<'  => $alloc->Procedure( $alloc->Sym('<' ), \&num_lt, is_applicative => true ),
            '>=' => $alloc->Procedure( $alloc->Sym('>='), \&num_ge, is_applicative => true ),
            '<=' => $alloc->Procedure( $alloc->Sym('<='), \&num_le, is_applicative => true ),
        )
    }
}


## -----------------------------------------------------------------------------
my $sys  = System->new;
my $fact = $sys->compile(q[

; (defun fact (n)
;     (if (== n 0) 1
;         (* n (fact (- n 1)))))

(defun fact (n)
    (if (== n 0)
        (yield 1)
        (yield (* n (fact (- n 1))))))

(fact 3)

]);

my $fib = $sys->compile(q[

; (defun fib (n)
;         (if (< n 2) n
;             (+ (fib (- n 2))
;                (fib (- n 1)))))

(defun fib (n)
    (if (< n 2)
        (yield n)
        (+ (yield (fib (- n 2)))
           (yield (fib (- n 1))))))

(fib 3)

]);

my $fact_ctx = $sys->spawn_context( $fact );
my $fib_ctx  = $sys->spawn_context( $fib );
my @halted   = $sys->run;

foreach my $ctx (@halted) {
    my ($last) = $ctx->trace;
    say '-' x 40;
    say $last;
    say "  - ", join "\n  - " => $last->env->chain;
}



