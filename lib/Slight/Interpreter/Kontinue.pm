use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];


class Context {
    field $alloc :param :reader;
    field $env   :param :reader;
}

class Kontinue {
    field $ctx  :param :reader;
    field $kont :param :reader = undef;

    method kontinue {
        ...
    }

    method LOG ($fmt, @args) {
        @args = map {
        blessed $_ ? $_ isa Env ? $_->short_hash : $ctx->alloc->Util->pprint($_) : $_
        } @args;
        say sprintf "+ %s : ${fmt}" => __CLASS__, @args
    }
}

class Return :isa(Kontinue) {
    field $value :param :reader;

    method kontinue {
        Slight::DEBUG && $self->LOG('[ value: %s ]', $value);
        return $self->kont->kontinue( $value );
    }
}

class Drop :isa(Kontinue) {
    method kontinue ($value=undef) {
        Slight::DEBUG && $self->LOG('[ ^value: %s ]', $value // '~');
        return $self->kont;
    }
}


class Error :isa(Kontinue) {
    field $error :param :reader;

    method kontinue {
        Slight::DEBUG && $self->LOG('[ error: %s ]', $error);
        return undef;
    }
}

class Halt :isa(Kontinue) {
    field $result :reader;

    method kontinue ($value=undef) {
        $result = $value // $self->ctx->alloc->Nil;
        Slight::DEBUG && $self->LOG('[ result: %s ]', $value);
        return undef;
    }
}

class Eval::Expr :isa(Kontinue) {
    field $expr :param :reader;

    method kontinue {
        Slight::DEBUG && $self->LOG('[ expr: %s ]', $expr);
        given (blessed $expr) {
            when ('Partial') {
                return Return->new(
                    value => $self->ctx->alloc->Util->CaptureClosure( $expr, $self->ctx->env ),
                    kont  => $self->kont,
                    ctx   => $self->ctx
                )
            }
            when ('Cons') {
                return Eval::Expr->new(
                    expr => $self->ctx->alloc->Util->Head($expr),
                    ctx  => $self->ctx,
                    kont => Eval::Head->new(
                        tail => $self->ctx->alloc->Util->Tail($expr),
                        kont => $self->kont,
                        ctx  => $self->ctx
                    )
                )
            }
            when ('Sym') {
                if (my $found = $self->ctx->alloc->Util->Lookup( $expr, $self->ctx->env )) {
                    return Return->new(
                        value => $found,
                        kont  => $self->kont,
                        ctx   => $self->ctx
                    )
                } else {
                    return Error->new(
                        error => $self->ctx->alloc->Str(
                            sprintf 'Cannot find (%s) in Env (%s)' =>
                                $self->ctx->alloc->Util->pprint($expr),
                                $self->ctx->env->short_hash
                        ),
                        kont => $self->kont,
                        ctx  => $self->ctx
                    )
                }
            }
            when ('Condition') {
                return Eval::Expr->new(
                    expr => $self->ctx->alloc->Util->First($expr),
                    ctx  => $self->ctx,
                    kont => Cond->new(
                        cond => $expr,
                        kont => $self->kont,
                        ctx  => $self->ctx
                    ),
                )
            }
            default {
                return Return->new(
                    value => $expr,
                    kont  => $self->kont,
                    ctx   => $self->ctx
                );
            }
        }
    }
}

class Eval::Head :isa(Kontinue) {
    field $tail :param :reader;

    method kontinue ($call) {
        Slight::DEBUG && $self->LOG('[ @call: %s, tail: %s ]', $call, $tail);
        return Eval::Args->new(
            args => $tail,
            ctx  => $self->ctx,
            kont => Apply->new(
                call => $call,
                kont => $self->kont,
                ctx  => $self->ctx
            )
        )
    }
}

class Eval::Args :isa(Kontinue) {
    field $args :param :reader;
    field $done :param :reader = +[];

    method kontinue ($value=undef) {
        push @$done => $value if defined $value;
        Slight::DEBUG && $self->LOG('[ args: %s, @done: (%s) ]', $args, join ', ' => map $self->ctx->alloc->Util->pprint($_), @$done);
        if ($args->is_nil) {
            return Return->new(
                value => $self->ctx->alloc->Util->ListOf( @$done ),
                kont  => $self->kont,
                ctx   => $self->ctx
            )
        } else {
            my $next = $self->ctx->alloc->Util->Head($args);
            $args = $self->ctx->alloc->Util->Tail($args);
            return Eval::Expr->new(
                expr => $next,
                kont => $self,
                ctx  => $self->ctx,
            )
        }
    }
}

class Apply :isa(Kontinue) {
    field $call :param :reader;

    method kontinue ($args) {
        Slight::DEBUG && $self->LOG('[ call: %s, @args: %s ]', $call, $args);
        given (blessed $call) {
            when ('Builtin') {
                my $native = $self->ctx->alloc->deref_native( $call->index );
                return Return->new(
                    value => $native->($args),
                    kont  => $self->kont,
                    ctx   => $self->ctx
                );
            }
            when ('Lambda') {
                my $params = $self->ctx->alloc->Util->First($call);
                my $body   = $self->ctx->alloc->Util->Second($call);
                my $local  = $self->ctx->alloc->Util->Third($call);
                my $bound  = $self->ctx->alloc->Util->BindParams( $params, $args, $local );
                my $scope  = Context->new( alloc => $self->ctx->alloc, env => $bound );
                return Scope::Enter->new(
                    ctx  => $scope,
                    kont => Eval::Expr->new(
                        expr => $body,
                        ctx  => $scope,
                        kont => Scope::Leave->new(
                            kont => $self->kont,
                            ctx  => $self->ctx,
                        )
                    )
                )
            }
            default {
                return Error->new(
                    error => $self->ctx->alloc->Str('Cannot call '.$self->ctx->alloc->Util->pprint($call)),
                    kont  => $self->kont,
                    ctx   => $self->ctx
                )
            }
        }
    }
}

class Scope::Enter :isa(Kontinue) {
    method kontinue {
        Slight::DEBUG && $self->LOG('[ ++enterScope(%s)  ]', $self->ctx->env);
        return $self->kont;
    }
}

class Scope::Leave :isa(Kontinue) {
    method kontinue ($result) {
        Slight::DEBUG && $self->LOG('[ result: %s, --leaveScope(%s)  ]', $result, $self->ctx->env);
        return Return->new(
            value => $result,
            kont  => $self->kont,
            ctx   => $self->ctx
        )
    }
}

class Cond :isa(Kontinue) {
    field $cond :param :reader;

    method kontinue ($result) {
        Slight::DEBUG && $self->LOG('[ result: %s  ]', $result);
        return Eval::Expr->new(
            kont => $self->kont,
            ctx  => $self->ctx,
            expr => $result isa Bool && $result->is_true
                ? $self->ctx->alloc->Util->Second($cond)
                : $self->ctx->alloc->Util->Third($cond)
        )
    }
}

class Bind :isa(Kontinue) {
    method kontinue {

    }
}

class Interpreter::Kontinue {
    field $alloc :param :reader;

    field @trace :reader;

    method run ($exprs, $env) {
        my $ctx   = Context->new( alloc => $alloc, env => $env );
        my $kont  = Halt->new( ctx => $ctx );
        my @exprs = @$exprs;
        while (@exprs) {
            my $next = shift @exprs;
            $kont = Eval::Expr->new(
                expr => $next,
                ctx  => $ctx,
                kont => scalar @exprs == 0 ? $kont : Drop->new(
                    ctx  => $ctx,
                    kont => $kont,
                )
            )
        }
        return $self->step( $kont );
    }

    method step ($kont) {
        do {
            push @trace => $kont;
            $kont = $kont->kontinue;
        } while defined $kont;
        return $trace[-1]->value;
    }
}




