use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

class Interpreter::CEK {
    field $alloc :param :reader;

    field $steps :reader = 0;

    my method LOG ($fmt, @args) {
        say sprintf("%05d | ${fmt}", $steps, map {
                blessed $_
                    ? $_ isa Env
                        ? $_->short_hash
                        : $alloc->Util->pprint($_)
                    : $_
                } @args)
    }

    method run ($exprs, $env) {
        my @exprs = @$exprs;
        return $self->execute(shift @exprs, $env, sub ($c, $e) {
            return $c, $e, undef if scalar @exprs == 0;
            return shift @exprs, $env, __SUB__;
        })
    }

    method execute ($expr, $env, $kont) {
        Slight::DEBUG && $self->&LOG('>> BEGIN %s %s' => $expr, $env);
        while (true) {
            $steps++;
            Slight::DEBUG && say '-' x $Slight::TERM_WIDTH;
            ($expr, $env, $kont) = defined $expr ? $self->evaluate( $expr, $env, $kont ) : $kont->();
            last if not defined $kont;
        }
        Slight::DEBUG && $self->&LOG('<< END %s %s' => $expr, $env);
        return $expr;
    }

    my method return_value ($expr, $env, $kont) {
        return undef, $env, sub { $kont->( $expr, $env ) };
    }

    method evaluate ($expr, $env, $kont) {
        Slight::DEBUG && $self->&LOG('~> EVAL %s' => $expr);
        given (blessed $expr) {
            when ('Partial') {
                Slight::DEBUG && $self->&LOG('() CLOSING OVER %s @ %s' => $expr, $env->short_hash );
                return $self->&return_value( $alloc->Util->CaptureClosure( $expr, $env ), $env, $kont );
            }
            when ('Sym') {
                Slight::DEBUG && $self->&LOG('?> LOOKUP %s', $expr);
                if (my $found = $alloc->Util->Lookup($expr, $env)) {
                    Slight::DEBUG && $self->&LOG('<? FOUND %s := %s', $expr, $found);
                    return $self->&return_value( $found, $env, $kont );
                } else {
                    return $alloc->Str("Could not find (".$alloc->Util->pprint($expr).") in Env".$env->short_hash), $env, undef;
                }
            }
            when ('Cons') {
                my $head = $alloc->Util->Head($expr);
                my $tail = $alloc->Util->Tail($expr);
                Slight::DEBUG && $self->&LOG('-> EVAL/HEAD %s', $head);
                return $head, $env, sub ($call, $e) {
                    Slight::DEBUG && $self->&LOG('<- EVAL/HEAD %s ~ %s', $head, $call);
                    return $self->evaluate_args( $call, $tail, $e, $kont )
                }
            }
            when ('Condition') {
                my $cond     = $alloc->Util->First($expr);
                my $if_true  = $alloc->Util->Second($expr);
                my $if_false = $alloc->Util->Third($expr);
                Slight::DEBUG && $self->&LOG('?> COND %s', $cond);
                return $cond, $env, sub ($result, $e) {
                    Slight::DEBUG && $self->&LOG('<? COND %s ~ %s', $cond, $result);
                    if ($result isa Bool && $result->is_true) {
                        return $if_true, $e, $kont;
                    } else {
                        return $if_false, $e, $kont;
                    }
                }
            }
            default {
                Slight::DEBUG && $self->&LOG('<- RETURN %s', $expr);
                return $self->&return_value( $expr, $env, $kont );
            }
        }
    }

    method evaluate_args ($call, $args, $env, $kont) {
        Slight::DEBUG && $self->&LOG('+> EVAL/ARGS %s -> ()', $args);
        my $first = $alloc->Util->Head( $args );
        my $rest  = $alloc->Util->Tail( $args );
        my @done;
        return $first, $env, sub ($arg, $e) {
            push @done => $arg;
            if ($rest->is_nil) {
                my $done = $alloc->Util->ListOf( @done );
                Slight::DEBUG && $self->&LOG('<+ EVAL/ARGS () <- %s', $done);
                return $self->apply( $call, $done, $env, $kont );
            } else {
                Slight::DEBUG && $self->&LOG('<< EVAL/ARGS %s ~ %s', $rest, join ', ' => map $alloc->Util->pprint($_), @done);
                my $next = $alloc->Util->Head($rest);
                $rest = $alloc->Util->Tail($rest);
                return $next, $e, __SUB__;
            }
        }
    }

    method apply ($call, $args, $env, $kont) {
        Slight::DEBUG && $self->&LOG('@> APPLY %s %s', $call, $args);
        given (blessed $call) {
            when ('Builtin') {
                Slight::DEBUG && $self->&LOG('@! APPLY/BIF %s %s', $call, $args);
                my $native = $alloc->deref_native( $call->index );
                return $self->&return_value( $native->( $args ), $env, $kont );
            }
            when ('Lambda') {
                Slight::DEBUG && $self->&LOG('@! APPLY/LAMBDA %s %s', $call, $args);
                my $params = $alloc->Util->First($call);
                my $body   = $alloc->Util->Second($call);
                my $local  = $alloc->Util->Third($call);
                return $body, $alloc->Util->BindParams( $params, $args, $local ), sub ($c, $e) {
                    Slight::DEBUG && $self->&LOG('@< LEAVE (%s) ^(%s)', $e, $env);
                    return $self->&return_value( $c, $env, $kont );
                }
            }
            default {
                return $alloc->Str("Could not call (".$alloc->Util->pprint($call).")"), $env, undef;
            }
        }
    }
}
