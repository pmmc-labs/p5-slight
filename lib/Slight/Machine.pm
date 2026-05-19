
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight::Allocator;
use Slight::Parser;

## ------------------------------------------
## Interpreter ...
## ------------------------------------------

class Slight::Machine {
    field $alloc  :param :reader = undef;
    field $parser :param :reader = undef;

    field $tick = 0;

    field @queue;
    field @environment;

    ADJUST {
        $alloc   //= Slight::Allocator->new;
        $parser  //= Slight::Parser->new( alloc => $alloc );
    }

    method current_env { $environment[-1] }

    method init (%bindings) {
        push @environment => $alloc->Env(%bindings);
        return $self;
    }

    method add_effect ($e) {
        push @environment => $alloc->Env( $environment[-1], $e->provides->%* );
        return $self;
    }

    ## ------------------------------------------
    ## Continuations
    ## ------------------------------------------

    use constant ERROR      => 'ERROR';
    use constant HALT       => 'HALT';
    use constant HOST       => 'HOST';

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

    sub Error ($env, $error)  { [ ERROR, $env, $error ] }
    sub Halt  ($env)          { [ HALT,  $env ] }

    sub Host  ($env, $effect, $action) {
        [ HOST, $env, $effect, $action ]
    }

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
    ## Evaluation ...
    ## ------------------------------------------

    method run ($source, %config) {
        my @exprs = $parser->parse($source);
        my $env   = $environment[-1];

        push @queue =>
            Halt($env),
            reverse map {
                Drop($env),
                EvalExpr($env, $_)
            } @exprs;

        my $result;
        while (@queue) {
            my ($op, $env, @rest) = $self->execute(\@exprs, $env)->@*;
            given ($op) {
                when (HOST) {
                    my ($effect, $action, @args) = @rest;
                    push @queue => $effect->handler($self, $action, $env, @args);
                }
                when (HALT) {
                    ($result) = @rest;
                }
                when (ERROR) {
                    die 'ERROR: '.(join ' ' => map $_->to_string, @rest);
                }
            }
        }

        return $result;
    }

    method thread_computation ($env, @stack) {
        # append this stack to the previous opcode
        push $queue[-1]->@* => @stack;
        # and pass on the environment, ....unless
        # it is a LEAVE_SCOPE opcode, in which case,
        # we will preserve it's environment and
        # not overwrite it
        $queue[-1]->[1] = $env unless $queue[-1]->[0] eq LEAVE_SCOPE;
    }

    method execute ($exprs, $env) {
        while (@queue) {
            $tick++;
            my $next = pop @queue;
            my ($op, $env, @stack) = @$next;
            Slight::DEBUG_STEP && Slight::Tools::Debug::debug_step(
                (scalar grep { $_->[0] eq LEAVE_SCOPE } @queue),
                $tick,
                $op,
                $env,
                @stack
            );
            given ($op) {
                when (HOST) {
                    return $next;
                }
                when (HALT) {
                    return $next;
                }
                when (ERROR) {
                    return $next;
                }
                when (JUST) {
                    # append the stack ...
                    $self->thread_computation($env, @stack);
                }
                when (DROP) {
                    # drop the stack ...
                    $self->thread_computation($env);
                }
                when (ENTER_SCOPE) {
                    # TODO - add `defer` support
                    #... but do nothing for now
                }
                when (LEAVE_SCOPE) {
                    # ... pass the stack, and the
                    # restore the upper/older env
                    # TODO - handle `defer`s
                    $self->thread_computation($env, @stack);
                }
                when (BIND) {
                    my ($sym, $term) = @stack;
                    my %local = ($sym->raw, $term);
                    my $local = $alloc->Env( $env, %local );
                    push @queue => Just( $local, $alloc->Nil );
                    Slight::DEBUG_BIND && Slight::Tools::Debug::debug_bind(
                        (scalar grep { $_->[0] eq LEAVE_SCOPE } @queue),
                        $tick,
                        $env,
                        $local,
                        %local
                    );
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

            Slight::DEBUG_QUEUE && Slight::Tools::Debug::debug_queue($tick, @queue);
        }
    }

    method eval ($expr, $env) {
        given (blessed $expr) {
            when ('Slight::Term::Cons') {
                return EvalHead($env, $expr);
            }
            when ('Slight::Term::Sym') {
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
                        Slight::DEBUG_CALL && Slight::Tools::Debug::debug_call(
                            (scalar grep { $_->[0] eq LEAVE_SCOPE } @queue),
                            $tick,
                            $env,
                            $local,
                            %local
                        );
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
