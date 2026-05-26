
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight::Machine;

## ------------------------------------------
## Effects ...
## ------------------------------------------

class Slight::Effect {
    use overload '""' => 'to_string';
    method handler  ($ctx, $a, $e, @a) { ... }
    method provides { +{} }
    method to_string { sprintf '*{%s}' => (split /\:\:/ => __CLASS__)[-1]  }
}

class Slight::Effect::SIGNAL :isa(Slight::Effect) {
    field $alloc  :param :reader;

    field $HALT  :reader;
    field $ERROR :reader;

    ADJUST {
        $HALT  = $alloc->Tag('!HALT');
        $ERROR = $alloc->Tag('!ERROR');
    }

    method handler  ($ctx, $action, $env, @args) {
        given ($action->raw) {
            when ('!HALT') {
                $ctx->result = $args[0] // $alloc->Nil;
                $ctx->last_env = $env;
                $ctx->halt;
                return ();
            }
            when ('!ERROR') {
                $ctx->error = $args[0];
                $ctx->last_env = $env;
                $ctx->halt;
                return ();
            }
        }
    }

    method provides {

        my sub _exit ($E) {
            return Slight::Machine::Host($E, $self, $HALT);
        }

        my sub raise ($E, @args) {
            return Slight::Machine::Host($E, $self, $ERROR),
                   Slight::Machine::EvalArgs($E, $alloc->List(@args));
        }

        return +{
            '!HALT'  => $HALT,
            '!ERROR' => $ERROR,
            'exit'   => $alloc->Procedure( $alloc->Sym('exit'),   \&_exit,   is_operative => true ),
            'raise'  => $alloc->Procedure( $alloc->Sym('raise'),  \&raise,   is_operative => true ),
        }
    }
}

class Slight::Effect::SYSTEM :isa(Slight::Effect) {
    field $alloc :param :reader;

    field %mailboxes;
    field %waiting;

    method handler  ($ctx, $action, $env, @args) {
        given ($action->raw) {
            when ('getpid') {
                return Slight::Machine::Just( $env, $ctx->PID );
            }
            when ('fork') {
                my ($expr) = @args;
                return Slight::Machine::Just( $env,
                    $ctx->runtime->fork_context( $ctx, +[ $expr ], $env )->PID
                )
            }
            when ('waitpid') {
                my ($pid) = @args;
                # TODO ... something here
                say "GOT WAITPID, ... SUSPENDING $ctx";
                $ctx->suspend;
                $ctx->runtime->watch( $pid, $ctx );
                return Slight::Machine::Drop( $env );
            }
            when ('recv') {
                $ctx->suspend;
                say "GOT RECV, ... SUSPENDING $ctx";
                $waiting{ $ctx->PID->to_string } = [ $env, $ctx ];
                return ();
            }
            when ('send') {
                my ($pid, $msg) = @args;
                if (my $reciever = $waiting{ $pid->to_string }) {
                    my ($e, $c) = @$reciever;
                    if ($c->is_waiting) {
                        say "GOT SEND FOR WAITING $c";
                        $c->resume;
                        $c->machine->kontinue( Slight::Machine::Just( $e, $msg ) );
                        return Slight::Machine::Just( $env, $alloc->Nil );
                    } else {
                        say join ', ' => map {
                            my ($_e, $_c) = $waiting{$_}->@*;
                            "$_e -> $_c"
                        } keys %waiting;
                        say "RECEIVER $c IS WAITING but not waiting???"
                    }
                }
                else {
                    die "RECEIVER $pid IS NOT WAITING???"
                }
                return ();
            }
            when ('yield') {
                my ($arg) = @args;
                return Slight::Machine::EvalExpr( $env, $arg );
            }
        }
    }

    method provides {

        my sub _getpid  ($E, @)     { return Slight::Machine::Host($E, $self, $alloc->Sym('getpid')) }
        my sub _fork    ($E, $expr) { return Slight::Machine::Host($E, $self, $alloc->Sym('fork'), $expr) }
        my sub _waitpid ($E, $pid)  {
            return Slight::Machine::Host($E, $self, $alloc->Sym('waitpid')),
                   Slight::Machine::EvalExpr($E, $pid);
        }

        my sub _yield ($E, $arg)  {
            return Slight::Machine::Host($E, $self, $alloc->Sym('yield'), $arg);
        }

        my sub _recv ($E)  {
            return Slight::Machine::Host($E, $self, $alloc->Sym('recv'));
        }

        my sub _send ($E, $pid, $msg)  {
            return Slight::Machine::Host($E, $self, $alloc->Sym('send')),
                   Slight::Machine::EvalArgs($E, $alloc->List($pid, $msg) );
        }

        return +{
            'getpid'  => $alloc->Procedure( $alloc->Sym('getpid'),  \&_getpid,  is_operative => true ),
            'fork'    => $alloc->Procedure( $alloc->Sym('fork'),    \&_fork,    is_operative => true ),
            'waitpid' => $alloc->Procedure( $alloc->Sym('waitpid'), \&_waitpid, is_operative => true ),
            'yield'   => $alloc->Procedure( $alloc->Sym('yield'),   \&_yield,   is_operative => true ),
            'recv'    => $alloc->Procedure( $alloc->Sym('recv'),    \&_recv,    is_operative => true ),
            'send'    => $alloc->Procedure( $alloc->Sym('send'),    \&_send,    is_operative => true ),
        }
    }
}

class Slight::Effect::TTY :isa(Slight::Effect) {
    field $alloc  :param :reader;
    field $input  :param :reader = \*STDIN;
    field $output :param :reader = \*STDOUT;
    field $error  :param :reader = \*STDERR;

    method handler  ($ctx, $action, $env, @args) {
        given ($action->raw) {
            when ('print') {
                $output->print( map $_->raw, @args );
                return Slight::Machine::Just($env, $alloc->Nil)
            }
            when ('say') {
                $output->print( (map $_->raw, @args), "\n" );
                return Slight::Machine::Just($env, $alloc->Nil)
            }
            when ('warn') {
                $error->print( (map $_->raw, @args), "\n" );
                return Slight::Machine::Just($env, $alloc->Nil)
            }
            when ('readline') {
                my $line = $input->getline;
                chomp $line;
                return Slight::Machine::Just($env, $alloc->Str($line))
            }
        }
    }

    method provides {
        my sub _print ($E, @args) {
            return Slight::Machine::Host($E, $self, $alloc->Sym('print')),
                   Slight::Machine::EvalArgs($E, $alloc->List(@args))
        }

        my sub _warn ($E, @args) {
            return Slight::Machine::Host($E, $self, $alloc->Sym('warn')),
                   Slight::Machine::EvalArgs($E, $alloc->List(@args))
        }

        my sub _say ($E, @args) {
            return Slight::Machine::Host($E, $self, $alloc->Sym('say')),
                   Slight::Machine::EvalArgs($E, $alloc->List(@args))
        }

        my sub _readline ($E) { return Slight::Machine::Host($E, $self, $alloc->Sym('readline')) }

        return +{
            'print'    => $alloc->Procedure( $alloc->Sym('print'   ), \&_print,    is_operative => true ),
            'say'      => $alloc->Procedure( $alloc->Sym('say'     ), \&_say,      is_operative => true ),
            'warn'     => $alloc->Procedure( $alloc->Sym('warn'    ), \&_warn,     is_operative => true ),
            'readline' => $alloc->Procedure( $alloc->Sym('readline'), \&_readline, is_operative => true ),
        }
    }
}
