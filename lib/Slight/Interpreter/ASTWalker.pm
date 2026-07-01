use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

class Interpreter::ASTWalker {
    field $alloc :param :reader;

    my method LOG ($depth, $fmt, @args) {
        my $indent = '';
        $indent = '  ' x $depth if $depth > 0;
        say $indent, sprintf $fmt, map blessed $_ ? $alloc->Util->pprint($_) : $_, @args;
    }

    method run ($exprs, $env) {
        my $depth  = 0;
        my $result = $alloc->Nil;
        foreach my $expr (@$exprs) {
            $result = $self->evaluate($expr, $env);
            Slight::DEBUG && $self->&LOG( $depth, '... statement ended with %s' => $result );
        }
        return $result;
    }

    method apply ($call, $args, $env, $depth=0) {
        Slight::DEBUG && $self->&LOG( $depth, 'APPLY %s %s' => $call, $args);
        given (blessed $call) {
            when ('Builtin') {
                my $native = $alloc->deref_native( $call->index );
                return $native->( $args );
            }
            when ('Lambda') {
                my $params = $alloc->Util->First($call);
                my $body   = $alloc->Util->Second($call);
                my $local  = $alloc->Util->Third($call);
                return $self->evaluate( $body, $alloc->Util->BindParams( $params, $args, $local ), $depth + 1 )
            }
            default { die 'WTF! cant apply a '.$alloc->Util->pprint($call) }
        }
    }

    method evaluate_args ($args, $env, $depth=0) {
        return $args if $args->is_nil;
        Slight::DEBUG && $self->&LOG( $depth, 'EVAL/ARGS %s' => $args );
        return $alloc->Cons(
            $self->evaluate( $alloc->Util->Head($args), $env, $depth + 1 ),
            $self->evaluate_args( $alloc->Util->Tail($args), $env, $depth + 1 )
        )
    }

    method evaluate ($expr, $env, $depth=0) {
        Slight::DEBUG && $self->&LOG( $depth, 'EVAL %s' => $expr );
        given (blessed $expr) {
            when ('Partial') {
                Slight::DEBUG && $self->&LOG( $depth, 'CLOSING OVER %s @ %s' => $expr, $env->short_hash );
                return $alloc->Util->CaptureClosure( $expr, $env );
            }
            when ('Sym') {
                Slight::DEBUG && $self->&LOG( $depth + 1, 'LOOKUP %s' => $expr );
                if (my $found = $alloc->Util->Lookup($expr, $env)) {
                    return $found;
                } else {
                    die "Could not find (".$alloc->Util->pprint($expr).") in Env";
                }
            }
            when ('Cons') {
                my $head = $alloc->Util->Head($expr);
                Slight::DEBUG && $self->&LOG( $depth, 'EVAL/HEAD %s' => $head );
                return $self->apply(
                    $self->evaluate( $head, $env, $depth + 1 ),
                    $self->evaluate_args( $alloc->Util->Tail($expr), $env, $depth + 1 ),
                    $env,
                    $depth
                )
            }
            when ('Condition') {
                Slight::DEBUG && $self->&LOG( $depth, 'COND');
                my $result = $self->evaluate( $alloc->Util->First($expr), $env, $depth + 1 );
                if ($result isa Bool && $result->is_true) {
                    Slight::DEBUG && $self->&LOG( $depth, 'BRANCH %s' => $result);
                    return $self->evaluate( $alloc->Util->Second($expr), $env, $depth + 1 );
                } else {
                    Slight::DEBUG && $self->&LOG( $depth, 'BRANCH %s' => $result);
                    return $self->evaluate( $alloc->Util->Third($expr), $env, $depth + 1 );
                }
            }
            default {
                return $expr;
            }
        }
    }
}
