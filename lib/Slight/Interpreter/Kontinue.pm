use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

class Context {
    field $alloc :param :reader;
    field $env   :param :reader;
    field $stats :param :reader;

    method derive ($e) {
        Context->new( alloc => $alloc, env => $e, stats => $stats )
    }

    my method allocate ($type, %args) {
        $stats->{total}++;
        $stats->{by_type}->{$type}++;
        return $type->new( ctx => $self, %args );
    }

    method Return     (%args) { $self->&allocate('Kontinue::Return'     => %args ) }
    method Drop       (%args) { $self->&allocate('Kontinue::Drop'       => %args ) }
    method Error      (%args) { $self->&allocate('Kontinue::Error'      => %args ) }
    method Halt       (%args) { $self->&allocate('Kontinue::Halt'       => %args ) }
    method EvalExpr   (%args) { $self->&allocate('Kontinue::EvalExpr'   => %args ) }
    method EvalHead   (%args) { $self->&allocate('Kontinue::EvalHead'   => %args ) }
    method EvalArgs   (%args) { $self->&allocate('Kontinue::EvalArgs'   => %args ) }
    method Apply      (%args) { $self->&allocate('Kontinue::Apply'      => %args ) }
    method LeaveScope (%args) { $self->&allocate('Kontinue::LeaveScope' => %args ) }
    method Cond       (%args) { $self->&allocate('Kontinue::Cond'       => %args ) }
    method Bind       (%args) { $self->&allocate('Kontinue::Bind'       => %args ) }
}

## -----------------------------------------------------------------------------

class Kontinue {
    field $ctx  :param :reader;
    field $kont :param :reader = undef;

    method kontinue { ... }

    method LOG ($fmt, @args) {
        @args = map {
        blessed $_ ? $_ isa Env ? $_->short_hash : $ctx->alloc->Util->pprint($_) : $_
        } @args;
        say sprintf "+ %s : ${fmt}" => __CLASS__, @args
    }
}

class Kontinue::Return :isa(Kontinue) {
    field $value :param :reader;

    method kontinue {
        Slight::DEBUG && $self->LOG('[ value: %s ]', $value);
        return $self->kont->kontinue( $value );
    }
}

class Kontinue::Drop :isa(Kontinue) {
    method kontinue ($value=undef) {
        Slight::DEBUG && $self->LOG('[ ^value: %s ]', $value // '~');
        return $self->kont;
    }
}


class Kontinue::Error :isa(Kontinue) {
    field $error :param :reader;

    method kontinue {
        Slight::DEBUG && $self->LOG('[ error: %s ]', $error);
        return undef;
    }
}

class Kontinue::Halt :isa(Kontinue) {
    field $result :reader;

    method kontinue ($value=undef) {
        $result = $value // $self->ctx->alloc->Nil;
        Slight::DEBUG && $self->LOG('[ result: %s ]', $value);
        return undef;
    }
}

class Kontinue::EvalExpr :isa(Kontinue) {
    field $expr :param :reader;

    method kontinue {
        Slight::DEBUG && $self->LOG('[ expr: %s ]', $expr);
        given (blessed $expr) {
            when ('Partial') {
                return $self->ctx->Return(
                    value => $self->ctx->alloc->Util->CaptureClosure( $expr, $self->ctx->env ),
                    kont  => $self->kont,
                )
            }
            when ('Cons') {
                return $self->ctx->EvalExpr(
                    expr => $self->ctx->alloc->Util->Head($expr),
                    kont => $self->ctx->EvalHead(
                        tail => $self->ctx->alloc->Util->Tail($expr),
                        kont => $self->kont,
                    )
                )
            }
            when ('Sym') {
                if (my $found = $self->ctx->alloc->Util->Lookup( $expr, $self->ctx->env )) {
                    return $self->ctx->Return(
                        value => $found,
                        kont  => $self->kont,
                    )
                } else {
                    return $self->ctx->Error(
                        error => $self->ctx->alloc->Str(
                            sprintf 'Cannot find (%s) in Env (%s)' =>
                                $self->ctx->alloc->Util->pprint($expr),
                                $self->ctx->env->short_hash
                        ),
                        kont => $self->kont,
                    )
                }
            }
            when ('Condition') {
                return $self->ctx->EvalExpr(
                    expr => $self->ctx->alloc->Util->First($expr),
                    kont => $self->ctx->Cond(
                        cond => $expr,
                        kont => $self->kont,
                    ),
                )
            }
            default {
                return $self->ctx->Return(
                    value => $expr,
                    kont  => $self->kont,
                );
            }
        }
    }
}

class Kontinue::EvalHead :isa(Kontinue) {
    field $tail :param :reader;

    method kontinue ($call) {
        Slight::DEBUG && $self->LOG('[ @call: %s, tail: %s ]', $call, $tail);
        return $self->ctx->EvalArgs(
            args => $tail,
            kont => $self->ctx->Apply(
                call => $call,
                kont => $self->kont,
            )
        )
    }
}

class Kontinue::EvalArgs :isa(Kontinue) {
    field $args :param :reader;
    field $done :param :reader = +[];

    method kontinue ($value=undef) {
        push @$done => $value if defined $value;
        Slight::DEBUG && $self->LOG('[ args: %s, @done: (%s) ]', $args, join ', ' => map $self->ctx->alloc->Util->pprint($_), @$done);
        if ($args->is_nil) {
            return $self->ctx->Return(
                value => $self->ctx->alloc->Util->ListOf( @$done ),
                kont  => $self->kont,
            )
        } else {
            return $self->ctx->EvalExpr(
                expr => $self->ctx->alloc->Util->Head($args),
                kont => $self->ctx->EvalArgs(
                    args => $self->ctx->alloc->Util->Tail($args),
                    done => $done,
                    kont => $self->kont,
                ),
            )
        }
    }
}

class Kontinue::Apply :isa(Kontinue) {
    field $call :param :reader;

    method kontinue ($args) {
        Slight::DEBUG && $self->LOG('[ call: %s, @args: %s ]', $call, $args);
        given (blessed $call) {
            when ('Builtin') {
                my $native = $self->ctx->alloc->deref_native( $call->index );
                return $self->ctx->Return(
                    value => $native->($args),
                    kont  => $self->kont
                );
            }
            when ('Lambda') {
                my $params = $self->ctx->alloc->Util->First($call);
                my $body   = $self->ctx->alloc->Util->Second($call);
                my $local  = $self->ctx->alloc->Util->Third($call);
                my $bound  = $self->ctx->alloc->Util->BindParams( $params, $args, $local );
                my $scope  = $self->ctx->derive( $bound );
                return $scope->EvalExpr(
                    expr => $body,
                    kont => $self->ctx->LeaveScope( kont => $self->kont )
                )

            }
            default {
                return $self->ctx->Error(
                    error => $self->ctx->alloc->Str('Cannot call '.$self->ctx->alloc->Util->pprint($call)),
                    kont  => $self->kont
                )
            }
        }
    }
}

class Kontinue::LeaveScope :isa(Kontinue) {
    method kontinue ($result) {
        Slight::DEBUG && $self->LOG('[ result: %s, --leaveScope(%s)  ]', $result, $self->ctx->env);
        return $self->ctx->Return(
            value => $result,
            kont  => $self->kont
        )
    }
}

class Kontinue::Cond :isa(Kontinue) {
    field $cond :param :reader;

    method kontinue ($result) {
        Slight::DEBUG && $self->LOG('[ result: %s  ]', $result);
        return $self->ctx->EvalExpr(
            kont => $self->kont,
            expr => $result isa Bool && $result->is_true
                ? $self->ctx->alloc->Util->Second($cond)
                : $self->ctx->alloc->Util->Third($cond)
        )
    }
}

class Kontinue::Bind :isa(Kontinue) {
    method kontinue {

    }
}

## -----------------------------------------------------------------------------

class Interpreter::Kontinue {
    field $alloc :param :reader;

    field $prev;

    method run ($exprs, $env) {
        my $stats = +{};
        my $ctx   = Context->new( alloc => $alloc, env => $env, stats => $stats );
        my $kont  = $ctx->Halt;
        my @exprs = @$exprs;
        while (@exprs) {
            my $next = shift @exprs;
            $kont = $ctx->EvalExpr(
                expr => $next,
                kont => scalar @exprs == 0 ? $kont : $ctx->Drop(kont => $kont)
            )
        }

        my $result = $self->step( $kont );
        #warn Data::Dumper::Dumper($stats);
        return $result;
    }

    method step ($kont) {
        do {
            $prev = $kont;
            $kont = $kont->kontinue;
        } while defined $kont;
        return $prev->value;
    }
}




