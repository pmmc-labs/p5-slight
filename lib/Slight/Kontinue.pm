
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

class Slight::Kontinue {
    use overload '""' => 'to_string';
    field $env   :param :reader;
    field @stack :reader;

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
            (__CLASS__ =~ s/Slight\:\:Kontinue\:\://r),
            substr($env->hash, 0, 6),
            (scalar @stack ? ('( '.(join ', ' => @stack).' )') : '()');
    }
}

## -----------------------------------------------------------------------------
## HOST Kontinues
## -----------------------------------------------------------------------------

class Slight::Kontinue::HOST :isa(Slight::Kontinue) {
    method HANDLE ($host, $ctx) { ... }
}

# basic halt/error
class Slight::Kontinue::Halt :isa(Slight::Kontinue::HOST) {
    method HANDLE ($host, $ctx) {
        $host->DEBUG && say ">> SYS.HALT in ${ctx}";
        $host->halt($ctx);
    }
}

class Slight::Kontinue::Error :isa(Slight::Kontinue::HOST) {
    field $error :param :reader;

    method HANDLE ($host, $ctx) {
        $host->DEBUG && say ">> SYS.ERROR in ${ctx}";
        $host->halt($ctx);
    }
}

# concurrency
class Slight::Kontinue::Yield :isa(Slight::Kontinue::HOST) {
    method HANDLE ($host, $ctx) {
        $host->DEBUG && say ">> SYS.YIELD in ${ctx}";
        $host->resume( $ctx );
    }
}

class Slight::Kontinue::Sleep :isa(Slight::Kontinue::HOST) {
    method HANDLE ($host, $ctx) {
        my ($timeout) = $self->stack;
        $host->schedule_timer( $timeout->raw, sub { $host->resume( $ctx ) });
        $ctx->enqueue( Slight::Kontinue::Just->new( env => $self->env )->PUSH( $host->alloc->Nil ) );
        $host->block( $ctx );
    }
}

class Slight::Kontinue::Timeout :isa(Slight::Kontinue::HOST) {
    method HANDLE ($host, $ctx) {
        my ($timeout, $callback) = $self->stack;
        $host->schedule_timer( $timeout->raw, sub {
            $ctx->enqueue(
                Slight::Kontinue::Drop->new( env => $self->env ),
                Slight::Kontinue::Apply::Call->new( env => $self->env, call => $callback )
            );
            $host->resume( $ctx );
        });
        $ctx->enqueue( Slight::Kontinue::Just->new( env => $self->env )->PUSH( $host->alloc->Nil ) );
        $host->resume( $ctx );
    }
}

class Slight::Kontinue::Fork :isa(Slight::Kontinue::HOST) {
    field $expr :param :reader;

    method HANDLE ($host, $ctx) {
        $host->DEBUG && say ">> SYS.FORK in ${ctx}";
        my $child = $host->spawn_context( $host->assemble( $self->env, $self->expr ), $ctx );
        $ctx->enqueue( Slight::Kontinue::Just->new( env => $self->env )->PUSH( $child->pid ) );
        $host->resume( $ctx );
    }
}

class Slight::Kontinue::Getpid :isa(Slight::Kontinue::HOST) {
    method HANDLE ($host, $ctx) {
        $host->DEBUG && say ">> SYS.GETPID in ${ctx}";
        $ctx->enqueue( Slight::Kontinue::Just->new( env => $self->env )->PUSH( $ctx->pid ) );
        $host->resume( $ctx );
    }
}

class Slight::Kontinue::Waitpid :isa(Slight::Kontinue::HOST) {
    method HANDLE ($host, $ctx) {
        my @pids = $self->stack;
        $host->DEBUG && say ">> SYS.WAITPID in ${ctx} for ", join ', ' => @pids;
        $host->block( $ctx );
        $host->wait_for( $ctx, @pids );
    }
}

class Slight::Kontinue::Send :isa(Slight::Kontinue::HOST) {
    method HANDLE ($host, $ctx) {
        $host->DEBUG && say ">> SYS.SEND in ${ctx}";
        my ($pid, $msg) = $self->stack;
        if (my $recvr = $host->lookup_pid( $pid )) {
            $host->DEBUG && say ">> -- SENDING LETTER ${msg} to ${pid} in ${ctx}";
            $host->enqueue_message( $ctx->pid, $pid, $msg );
            $host->resume( $recvr );
        } else {
            $host->DEBUG && say ">> -- DEAD LETTER ${msg} to ${pid} in ${ctx}";
            $host->discard_message( $ctx->pid, $pid, $msg );
        }
        $ctx->enqueue( Slight::Kontinue::Just->new( env => $self->env )->PUSH( $host->alloc->Nil ) );
        $host->resume( $ctx );
    }
}

class Slight::Kontinue::Recv :isa(Slight::Kontinue::HOST) {
    method HANDLE ($host, $ctx) {
        $host->DEBUG && say ">> SYS.RECV in ${ctx}";
        if (my $letter = $host->dequeue_message( $ctx->pid )) {
            $host->DEBUG && say ">> -- WEVE GOT MAIL! ${letter} in ${ctx}";
            $ctx->enqueue( Slight::Kontinue::Just->new( env => $self->env )->PUSH( $letter->msg ) );
            $host->resume( $ctx );
        } else {
            $host->DEBUG && say ">> -- NO MAIL TODAY! in ${ctx}";
            $ctx->enqueue( $self );
            $host->block( $ctx );
        }
    }
}

## -----------------------------------------------------------------------------
## STEP Kontinues
## -----------------------------------------------------------------------------

class Slight::Kontinue::STEP :isa(Slight::Kontinue) {
    method STEP ($ctx) { ... }
}

# Other Kontinues

class Slight::Kontinue::Just :isa(Slight::Kontinue::STEP) {
    method STEP ($ctx) {
        $ctx->thread_computation( $self->env, $self->stack );
    }
}

class Slight::Kontinue::Drop :isa(Slight::Kontinue::STEP) {
    method STEP ($ctx) {
        $ctx->thread_computation( $self->env );
    }
}

class Slight::Kontinue::Eval::Expr :isa(Slight::Kontinue::STEP) {
    field $expr :param :reader;

    method STEP ($ctx) {
        given (blessed $expr) {
            when ('Slight::Term::Sym') {
                return Slight::Kontinue::Just->new( env => $self->env )->PUSH(
                    $self->env->lookup( $expr )
                );
            }
            when ('Slight::Term::Cons') {
                return Slight::Kontinue::Eval::Head->new(
                    env  => $self->env,
                    head => $expr->head,
                    rest => $expr->tail,
                );
            }
            default {
                return Slight::Kontinue::Just->new( env => $self->env )->PUSH(
                    $expr
                );
            }
        }
    }

    method to_string { sprintf '%s :expr %s' => $self->SUPER::to_string, $expr }
}

class Slight::Kontinue::Eval::Head :isa(Slight::Kontinue::STEP) {
    field $head :param :reader;
    field $rest :param :reader;

    method STEP ($ctx) {
        return Slight::Kontinue::Apply::Expr->new( env => $self->env, args => $rest ),
                Slight::Kontinue::Eval::Expr->new( env => $self->env, expr => $head );
    }

    method to_string { sprintf '%s :head %s :rest %s' => $self->SUPER::to_string, $head, $rest }
}

class Slight::Kontinue::Eval::Rest :isa(Slight::Kontinue::STEP) {
    field $rest :param :reader;

    method STEP ($ctx) {
        if ($rest->is_nil) {
            return Slight::Kontinue::Just->new( env => $self->env )->PUSH( $self->stack );
        } else {
            return Slight::Kontinue::Eval::Rest->new( env => $self->env, rest => $rest->tail )->PUSH( $self->stack ),
                    Slight::Kontinue::Eval::Expr->new( env => $self->env, expr => $rest->head );
        }
    }

    method to_string { sprintf '%s :rest %s' => $self->SUPER::to_string, $rest }
}

class Slight::Kontinue::Apply::Expr :isa(Slight::Kontinue::STEP) {
    field $args :param :reader;

    method STEP ($ctx) {
        my ($call) = $self->stack;
        if ($call->is_applicative) {
            return Slight::Kontinue::Apply::Call->new( env => $self->env, call => $call ),
                    Slight::Kontinue::Eval::Rest->new( env => $self->env, rest => $args );
        } else {
            return Slight::Kontinue::Apply::Call->new( env => $self->env, call => $call )
                              ->PUSH( $self->env, $self->args->is_nil ? () : $self->args->uncons );
        }
    }

    method to_string { sprintf '%s :args %s' => $self->SUPER::to_string, $args }
}

class Slight::Kontinue::Apply::Call :isa(Slight::Kontinue::STEP) {
    field $call :param :reader;

    method STEP ($ctx) {
        my @args = $self->stack;
        given (blessed $call) {
            when ('Slight::Term::Procedure') {
                if ($call->is_applicative) {
                    return Slight::Kontinue::Just->new( env => $self->env )->PUSH( $call->body->( @args ) );
                } else {
                    return $call->body->( @args );
                }
            }
            when ('Slight::Term::Lambda') {
                my %local;
                if (!$call->params->is_nil) {
                    my @params = $call->params->uncons;
                    while (@params) {
                        my $param = shift @params;
                        $local{ $param->raw } = shift @args;
                    }
                }
                if (my $rec = $call->name) {
                    $local{ $rec->raw } = $call;
                }
                my $local = $ctx->derive_env( $call->env, %local );
                return Slight::Kontinue::Scope::Leave->new( env => $self->env ),
                         Slight::Kontinue::Eval::Expr->new( env => $local, expr => $call->body ),
                       Slight::Kontinue::Scope::Enter->new( env => $local );
            }
            default {
                die "Unknown callable type: $call";
            }
        }
    }

    method to_string { sprintf '%s :call %s' => $self->SUPER::to_string, $call }
}

class Slight::Kontinue::Bind :isa(Slight::Kontinue::STEP) {
    field $name :param :reader;

    method STEP ($ctx) {
        my ($value) = $self->stack;
        return Slight::Kontinue::Drop->new( env => $ctx->bind_variable( $self->env, $name, $value ) )
    }

    method to_string { sprintf '%s :name %s' => $self->SUPER::to_string, $name }
}

class Slight::Kontinue::Cond :isa(Slight::Kontinue::STEP) {
    field $if_true   :param :reader;
    field $if_false  :param :reader;

    method STEP ($ctx) {
        my ($condition) = $self->stack;
        if ($condition isa Slight::Term::Bool && $condition->is_true) {
            return Slight::Kontinue::Eval::Expr->new( env => $self->env, expr => $if_true );
        } else {
            return Slight::Kontinue::Eval::Expr->new( env => $self->env, expr => $if_false );
        }
    }

    method to_string { sprintf '%s :if-true %s :if-false %s' => $self->SUPER::to_string, $if_true, $if_false }
}

class Slight::Kontinue::Scope::Enter :isa(Slight::Kontinue::STEP) {
    method STEP ($ctx) {
        return ();
    }
}

class Slight::Kontinue::Scope::Leave :isa(Slight::Kontinue::STEP) {
    field $orig_env :reader;

    ADJUST { $orig_env = $self->env }

    method STEP ($ctx) {
        $ctx->thread_computation( $orig_env, $self->stack );
    }

    method to_string { sprintf '%s :orig-env %s' => $self->SUPER::to_string, substr($orig_env->hash, 0, 6) }
}
