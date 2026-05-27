
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;

class Context {
    field $alloc :param :reader;
    field $queue :param :reader;

    field @env_stack :reader;

    method current_environment { $env_stack[-1] }

    method update_env ($env, %local) {
        my $local = $alloc->Env( $env, %local );
        push @env_stack => $local;
        return $local;
    }

    method thread_computation ($env, @stack) {
        my $tos = $queue->[-1];
        $tos->THREAD( $env );
        $tos->PUSH( @stack );
        return ();
    }

    method run_until_host ($env) {
        push @env_stack => $env;
        while (@$queue) {
            say '-' x 80;
            say 'QUEUE: ', join ', ' => @$queue;
            my $next = pop @$queue;
            say '=' x 80;
            say "STEP: $next";
            return $next if $next isa Host;
            push @$queue => $next->STEP( $self );
        }
        say '!' x 80;
    }
}

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

class Host :isa(Kontinue) {
    field $effect :param :reader = undef;
}

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

class Bind :isa(Kontinue) {
    field $name :param :reader;

    method STEP ($ctx) {
        my ($value) = $self->stack;
        return Drop->new( env => $ctx->update_env( $self->env, $name->raw => $value ) )
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
            return Apply::Call->new( env => $self->env, call => $call )->PUSH( $self->stack );
        }
    }
}

class Apply::Call :isa(Kontinue) {
    field $call :param :reader;

    method STEP ($ctx) {
        my @args = $self->stack;
        given (blessed $call) {
            when ('Slight::Term::Procedure') {
                return Just->new( env => $self->env )->PUSH( $call->body->( @args ) );
            }
            default {
                ...;
            }
        }
    }
}

class Scope::Enter :isa(Kontinue) {}
class Scope::Leave :isa(Kontinue) {}


my $alloc = Slight::Allocator->new;

my $env = $alloc->Env(
    '+' => $alloc->Procedure(
        $alloc->Sym('+'),
        sub ($n, $m) { $alloc->Num( $n->raw + $m->raw ) },
        is_applicative => true
    ),
);

my $ctx = Context->new(
    alloc => $alloc,
    queue => +[
        Host->new( env => $env ),
        Bind->new( env => $env, name => $alloc->Sym('z') ),
        Eval::Expr->new( env => $env, expr =>
            $alloc->List( $alloc->Sym('+'), $alloc->Sym('x'), $alloc->Sym('y') )
        ),
        Bind->new( env => $env, name => $alloc->Sym('y') ),
        Eval::Expr->new( env => $env, expr => $alloc->Num(20) ),
        Bind->new( env => $env, name => $alloc->Sym('x') ),
        Eval::Expr->new( env => $env, expr => $alloc->Num(10) ),
    ]
);

my $host = $ctx->run_until_host( $env );

say '-' x 40;
say $host;
say "  - ", join "\n  - " => $host->env->chain;
say "SCOPES:";
say "  - ", join "\n  - " => $ctx->environments;



