
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight::Allocator;

## ------------------------------------------
## Interpreter ...
## ------------------------------------------

class Slight::Machine {
    field $alloc :param :reader;

    field $tick = 0;
    field @queue;

    field %watchers;

    ## ------------------------------------------
    ## Continuations
    ## ------------------------------------------

    use constant HOST       => 'HOST';
    use constant ERROR      => 'ERROR';

    use constant JUST       => 'JUST';
    use constant DROP       => 'DROP';

    use constant COND       => 'COND';
    use constant BIND       => 'BIND';

    use constant EVAL_EXPR  => 'EVAL_EXPR';
    use constant EVAL_HEAD  => 'EVAL_HEAD';
    use constant EVAL_ARGS  => 'EVAL_ARGS';

    use constant APPLY_EXPR => 'APPLY_EXPR';
    use constant APPLY_CALL => 'APPLY_CALL';

    use constant ENTER_SCOPE => 'ENTER_SCOPE';
    use constant LEAVE_SCOPE => 'LEAVE_SCOPE';

    ## Continuation constructors

    sub Error ($env, $error)  { [ ERROR, $error ] }

    sub Host  ($env, @args) { [ HOST, $env, @args ] }

    sub Drop ($env)         { [ DROP, $env ] }
    sub Just ($env, @stack) { [ JUST, $env, @stack ] }

    # expects Value on stack
    sub Bind ($env, $sym) { [ BIND, $env, $sym ] }

    # expects condition result on stack
    sub Cond ($env, $if_true, $if_false) { [ COND, $env, $if_true, $if_false ] }

    sub EvalExpr ($env, $expr)          { [ EVAL_EXPR, $env, $expr ] }
    sub EvalHead ($env, $list)          { [ EVAL_HEAD, $env, $list->head, $list->tail ] }
    sub EvalArgs ($env, $args, @evaled) { [ EVAL_ARGS, $env, $args, @evaled ] }

    # expects call on stack
    sub ApplyExpr ($env, $args)        { [ APPLY_EXPR, $env, $args ] }
    sub ApplyCall ($env, $call, @args) { [ APPLY_CALL, $env, $call, @args ] }

    sub EnterScope ($env) { [ ENTER_SCOPE, $env ] }
    sub LeaveScope ($env) { [ LEAVE_SCOPE, $env ] }

    ## ------------------------------------------
    ## Monitoring
    ## ------------------------------------------

    method watch ($event, $f) { push @{ $watchers{$event} //= +[] } => $f }

    method trigger ($event, @args) {
        return unless exists $watchers{$event};
        $_->((scalar grep { $_->[0] eq LEAVE_SCOPE } @queue), $tick, @args)
            foreach $watchers{$event}->@*;
    }

    ## ------------------------------------------
    ## private helpers
    ## ------------------------------------------

    my sub compile_expressions ($exprs, $env) {
        reverse map {
            Drop($env),
            EvalExpr($env, $_)
        } @$exprs
    }

    my sub thread_computation ($q, $e, @s) {
        # append this stack to the previous opcode
        push $q->[-1]->@* => @s;
        # and pass on the environment, ....unless
        # it is a LEAVE_SCOPE opcode, in which case,
        # we will preserve it's environment and
        # not overwrite it
        $q->[-1]->[1] = $e unless $q->[-1]->[0] eq LEAVE_SCOPE;
    }

    my sub evaluate_term ($expr, $env, $a) {
        given (blessed $expr) {
            when ('Slight::Term::Cons') {
                return EvalHead($env, $expr);
            }
            when ('Slight::Term::Sym') {
                my $val = $env->lookup($expr);
                return defined $val
                    ? Just($env, $val)
                    : Error($env, $a->Sym("Unable to find $expr in Env"))
            }
            default {
                return Just($env, $expr)
            }
        }
    }

    ## ------------------------------------------
    ## Evaluation ...
    ## ------------------------------------------

    method is_running { scalar @queue > 0 }

    method kontinue (@konts) { push @queue => @konts }

    method compile ($exprs, $env, $on_exit) {
        push @queue => $on_exit, compile_expressions($exprs, $env);
        return $self;
    }

    method run_until_host ($on_error) {
        while (@queue) {
            $tick++;
            my $next = pop @queue;
            my ($op, $env, @stack) = @$next;
            $self->trigger(step => $op, $env, @stack);
            given ($op) {
                when (HOST) {
                    return $next;
                }
                when (ERROR) {
                    return Host( @$on_error, $next );
                }
                when (JUST) {
                    # append the stack ...
                    thread_computation(\@queue, $env, @stack);
                }
                when (DROP) {
                    # drop the stack ...
                    thread_computation(\@queue, $env);
                }
                when (ENTER_SCOPE) {
                    # TODO - add `defer` support
                    #... but do nothing for now
                }
                when (LEAVE_SCOPE) {
                    # ... pass the stack, and the
                    # restore the upper/older env
                    # TODO - handle `defer`s
                    thread_computation(\@queue, $env, @stack);
                }
                when (BIND) {
                    my ($sym, $term) = @stack;
                    my %local = ($sym->raw, $term);
                    my $local = $alloc->Env( $env, %local );
                    push @queue => Just( $local, $alloc->Nil );
                    $self->trigger(bind => $sym, $env, $local, %local);
                }
                when (COND) {
                    my $result = pop @stack;
                    my ($if_true, $if_false) = @stack;
                    if ($result isa Slight::Term::Bool && $result->is_true) {
                        push @queue => EvalExpr( $env, $if_true );
                    } else {
                        push @queue => EvalExpr( $env, $if_false );
                    }
                }
                default {
                    push @queue => $self->step( $next );
                }
            }
        }
    }

    method step ($step) {
        my ($op, $env, @rest) = $step->@*;
        given ($op) {
            when (EVAL_EXPR) {
                my ($expr) = @rest;
                return evaluate_term( $expr, $env, $alloc );
            }
            when (EVAL_HEAD) {
                my ($head, $rest) = @rest;
                return ApplyExpr( $env, $rest ),
                       evaluate_term( $head, $env, $alloc );
            }
            when (EVAL_ARGS) {
                my ($expr, @stack) = @rest;
                if ($expr->is_nil) {
                    return Just( $env, @stack );
                }
                else {
                    return EvalArgs( $env, $expr->tail, @stack ),
                           evaluate_term( $expr->head, $env, $alloc );
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
                    when ('Slight::Term::Procedure') {
                        if ($call->is_operative) {
                            return $call->body->( @args );
                        } else {
                            return Just( $env, $call->body->( @args ) );
                        }
                    }
                    when (/^Slight\:\:Term\:\:(Lambda|FExpr)$/) {
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

                        $self->trigger(call => $call, $env, $local, %local);

                        return LeaveScope( $env ),
                               EvalExpr( $local, $call->body ),
                               EnterScope( $env );
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
