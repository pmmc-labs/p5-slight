
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

class Slight::Kontinue {
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
            (__CLASS__ =~ s/Slight\:\:Kontinue\:\://r),
            substr($env->hash, 0, 6),
            (scalar @stack ? ('( '.(join ', ' => @stack).' )') : '()');
    }
}

# Host Kontinues

class Slight::Kontinue::HOST   :isa(Slight::Kontinue) {}
class Slight::Kontinue::Halt   :isa(Slight::Kontinue::HOST) {}
class Slight::Kontinue::Yield  :isa(Slight::Kontinue::HOST) {}
class Slight::Kontinue::Recv   :isa(Slight::Kontinue::HOST) {}
class Slight::Kontinue::Send   :isa(Slight::Kontinue::HOST) {}
class Slight::Kontinue::Getpid :isa(Slight::Kontinue::HOST) {}
class Slight::Kontinue::Fork   :isa(Slight::Kontinue::HOST) { field $expr :param :reader; }
class Slight::Kontinue::Error  :isa(Slight::Kontinue::HOST) { field $error :param :reader; }

# Other Kontinues

class Slight::Kontinue::Just :isa(Slight::Kontinue) {
    method STEP ($ctx) {
        $ctx->thread_computation( $self->env, $self->stack );
    }
}

class Slight::Kontinue::Drop :isa(Slight::Kontinue) {
    method STEP ($ctx) {
        $ctx->thread_computation( $self->env );
    }
}

class Slight::Kontinue::Eval::Expr :isa(Slight::Kontinue) {
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
}

class Slight::Kontinue::Eval::Head :isa(Slight::Kontinue) {
    field $head :param :reader;
    field $rest :param :reader;

    method STEP ($ctx) {
        return Slight::Kontinue::Apply::Expr->new( env => $self->env, args => $rest ),
                Slight::Kontinue::Eval::Expr->new( env => $self->env, expr => $head );
    }
}

class Slight::Kontinue::Eval::Rest :isa(Slight::Kontinue) {
    field $rest :param :reader;

    method STEP ($ctx) {
        if ($rest->is_nil) {
            return Slight::Kontinue::Just->new( env => $self->env )->PUSH( $self->stack );
        } else {
            return Slight::Kontinue::Eval::Rest->new( env => $self->env, rest => $rest->tail )->PUSH( $self->stack ),
                    Slight::Kontinue::Eval::Expr->new( env => $self->env, expr => $rest->head );
        }
    }
}

class Slight::Kontinue::Apply::Expr :isa(Slight::Kontinue) {
    field $args :param :reader;

    method STEP ($ctx) {
        my ($call) = $self->stack;
        if ($call isa Slight::Term::PID) {
            my $method = $self->args->head;
            my $args   = $self->args->tail;
            given ($method->raw) {
                when ('!') {
                    return Slight::Kontinue::Apply::Call->new(
                        env  => $self->env,
                        call => $self->env->lookup( $ctx->alloc->Sym('send') ),
                    )->PUSH(
                        $self->env,
                        $call,
                        $args->is_nil ? () : $args->uncons
                    )
                }
                default {
                    return Slight::Kontinue::Error->new(
                        env   => $self->env,
                        error => $ctx->alloc->Str("Unhandled PID method: ${method}")
                    )
                }
            }
        }
        elsif ($call->is_applicative) {
            return Slight::Kontinue::Apply::Call->new( env => $self->env, call => $call ),
                    Slight::Kontinue::Eval::Rest->new( env => $self->env, rest => $args );
        } else {
            return Slight::Kontinue::Apply::Call->new( env => $self->env, call => $call )
                              ->PUSH( $self->env, $self->args->is_nil ? () : $self->args->uncons );
        }
    }
}

class Slight::Kontinue::Apply::Call :isa(Slight::Kontinue) {
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
}

class Slight::Kontinue::Bind :isa(Slight::Kontinue) {
    field $name :param :reader;

    method STEP ($ctx) {
        my ($value) = $self->stack;
        return Slight::Kontinue::Drop->new( env => $ctx->bind_variable( $self->env, $name, $value ) )
    }
}

class Slight::Kontinue::Cond :isa(Slight::Kontinue) {
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
}

class Slight::Kontinue::Scope::Enter :isa(Slight::Kontinue) {
    method STEP ($ctx) {
        return ();
    }
}

class Slight::Kontinue::Scope::Leave :isa(Slight::Kontinue) {
    field $orig_env :reader;

    ADJUST { $orig_env = $self->env }

    method STEP ($ctx) {
        $ctx->thread_computation( $orig_env, $self->stack );
    }
}
