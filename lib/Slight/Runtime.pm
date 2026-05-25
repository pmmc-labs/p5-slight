
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight::Allocator;
use Slight::Machine;
use Slight::Parser;
use Slight::Term;

## -----------------------------------------------------------------------------
## Runtime
## -----------------------------------------------------------------------------

class Slight::Runtime::Context {
    field $runtime  :param :reader;
    field $root_env :param :reader;
    field $program  :param :reader;

    field $PID      :reader;
    field $machine  :reader;
    field $on_exit  :param :reader = undef;
    field $on_error :param :reader = undef;

    ADJUST {
        $PID = $runtime->alloc->PID;
        $on_exit  //= Slight::Machine::Host( $root_env, $runtime->SIGNAL, $runtime->SIGNAL->HALT  );
        $on_error //= Slight::Machine::Host( $root_env, $runtime->SIGNAL, $runtime->SIGNAL->ERROR );
        $machine = Slight::Machine->new( alloc => $runtime->alloc, context => $self );
    }

    field $halted  :reader(is_halted)  = false;
    field $waiting :reader(is_waiting) = false;
    field $result;
    field $error;
    field $last_env;

    method result   :lvalue { $result }
    method error    :lvalue { $error  }
    method last_env :lvalue { $last_env }

    method halt    { $halted = true  }
    method restart { $halted = false }

    method suspend { $waiting = true  }
    method resume  { $waiting = false }

    method compile          { $machine->compile( $program, $root_env ) }
    method run_until_host   { $machine->run_until_host }
    method kontinue (@next) { $machine->kontinue( @next ) }

    method fork (%args) {
        return __CLASS__->new(
            program  => $args{program},
            # copy these
            runtime  => $runtime,
            root_env => ($args{root_env} // ($last_env // $root_env)),
            # TODO:
            # - these should return to the
            #   parent context, and not just
            #   copy these
            #on_exit  => $on_exit,
            #on_error => $on_error,
        );
    }
}

class Slight::Runtime {
    field $alloc :param :reader = undef;

    field @environment;
    field @effects;

    field @running;
    field @waiting;
    field @halted;

    field %watchers;

    field $SIGNAL  :reader;
    field $CONSOLE :reader;
    field $SYSTEM  :reader;

    ADJUST {
        $alloc  //= Slight::Allocator->new;
        $SYSTEM  = Slight::Effect::SYSTEM->new( alloc => $alloc );
        $SIGNAL  = Slight::Effect::SIGNAL->new( alloc => $alloc );
        $CONSOLE = Slight::Effect::TTY->new( alloc => $alloc );
    }

    method parse_source ($src) {
        Slight::Parser->new( alloc => $alloc )->parse( $src )
    }

    ## -------------------------------------------------------------------------

    method spawn_context ($src) {

        my $program = ref $src ? $src : +[ $self->parse_source($src) ];

        my $ctx = Slight::Runtime::Context->new(
            runtime  => $self,
            root_env => $self->current_env,
            program  => $program
        );

        if (Slight::DEBUG) {
            Slight::DEBUG_STEP && $ctx->machine->watch(step => \&Slight::Tools::Debug::debug_step);
            Slight::DEBUG_BIND && $ctx->machine->watch(bind => \&Slight::Tools::Debug::debug_bind);
            Slight::DEBUG_CALL && $ctx->machine->watch(call => \&Slight::Tools::Debug::debug_call);
        }

        $ctx->compile;

        push @running => $ctx;
        return $ctx;
    }

    method fork_context ($parent, $src, $env) {

        my $program = ref $src ? $src : +[ $self->parse_source($src) ];

        my $ctx = $parent->fork(
            program  => $program,
            root_env => $env,
        );

        $ctx->machine->watchers->%* = $parent->machine->watchers->%*;


        if (Slight::DEBUG) {
            Slight::DEBUG_STEP && $ctx->machine->watch(step => \&Slight::Tools::Debug::debug_step);
            Slight::DEBUG_BIND && $ctx->machine->watch(bind => \&Slight::Tools::Debug::debug_bind);
            Slight::DEBUG_CALL && $ctx->machine->watch(call => \&Slight::Tools::Debug::debug_call);
        }

        $ctx->compile;

        push @running => $ctx;
        return $ctx;
    }

    ## -------------------------------------------------------------------------

    method watch ($pid, $to_notify) {
        push @{ $watchers{ $pid->hash } //= +[] } => $to_notify;
    }

    method run {
        while (@running) {
            my $ctx  = shift @running;
            my $host = $ctx->run_until_host;
            my ($HOST, $env, $effect, $action, @args) = @$host;
            my @next = $effect->handler( $ctx, $action, $env, @args );
            $ctx->kontinue( @next ) if @next;
            if ($ctx->is_halted) {
                if (my $ws = $watchers{ $ctx->PID->hash }) {
                    #say "RESUMING!!!!!!!!!!!!!";
                    unshift @running => map { $_->resume; $_ } reverse @$ws;
                }
                push @halted => $ctx;
            }
            elsif ($ctx->is_waiting) {
                # do nothing atm
                #say "WAITING!!!!!!!!!!!!!";
            }
            else {
                push @running => $ctx;
            }
        }
        return @halted;
    }

    ## -------------------------------------------------------------------------

    method current_env {
        $environment[-1] // die 'The root environment is not initialized';
    }

    method init (%config) {
        $self->initialize_root_environment;
        $self->initialize_core_effects;
        return $self;
    }

    method initialize_core_effects {
        push @effects => $SYSTEM, $SIGNAL, $CONSOLE;
        foreach my $effect (@effects) {
            push @environment => $alloc->Env( $environment[-1], $effect->provides->%* );
        }
        return $self;
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
            Slight::Machine::Just( $E, $alloc->Lambda( $p, $b, $E ) )
        }

        my sub quote  ($E, @terms) {
            Slight::Machine::Just( $E, (scalar @terms == 1) ? $terms[0] : $alloc->List(@terms) )
        }

        my sub defun  ($E, $sym, $p, $b) {
            return Slight::Machine::Bind( $E, $sym ),
                   Slight::Machine::EvalExpr( $E, $alloc->Lambda( $p, $b, $E, $sym ) );
        }

        my sub let  ($E, $sym, $value) {
            return Slight::Machine::Bind( $E, $sym ),
                   Slight::Machine::EvalExpr( $E, $value );
        }

        my sub _if ($E, $cond, $if_true, $if_false) {
            return Slight::Machine::Cond( $E, $if_true, $if_false ),
                   Slight::Machine::EvalExpr( $E, $cond )
        }

        my sub _do ($E, @exprs) {
            my @progn = reverse map {
                Slight::Machine::Drop($E),
                Slight::Machine::EvalExpr($E, $_)
            } @exprs;
            pop @progn;
            return @progn;
        }

        @environment = (
            $alloc->Env(
                # special forms
                'lambda' => $alloc->Procedure( $alloc->Sym('lambda' ), \&lambda, is_operative => true ),
                'quote'  => $alloc->Procedure( $alloc->Sym('quote'  ), \&quote,  is_operative => true ),
                'defun'  => $alloc->Procedure( $alloc->Sym('defun'  ), \&defun,  is_operative => true ),
                'let'    => $alloc->Procedure( $alloc->Sym('let'    ), \&let,    is_operative => true ),
                'if'     => $alloc->Procedure( $alloc->Sym('if'     ), \&_if,    is_operative => true ),
                'do'     => $alloc->Procedure( $alloc->Sym('do'     ), \&_do,    is_operative => true ),

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
        );
    }

}
