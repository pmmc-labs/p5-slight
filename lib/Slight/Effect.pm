
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
    method to_string { sprintf '*{%s}' => __CLASS__ }
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

        my sub _exit ($C, $E) {
            return Slight::Machine::Host($E, $self, $HALT);
        }

        my sub raise ($C, $E, @args) {
            return Slight::Machine::Host($E, $self, $ERROR),
                   Slight::Machine::EvalArgs($E, $alloc->List(@args));
        }

        my sub _pid ($C, $E, @) {
            return Slight::Machine::Just(
                $E, $alloc->Str(sprintf 'PID:%04d' => $C->PID)
            );
        }

        return +{
            '!HALT'  => $HALT,
            '!ERROR' => $ERROR,
            'exit'   => $alloc->Procedure( $alloc->Sym('exit'),  \&_exit, is_operative => true ),
            'raise'  => $alloc->Procedure( $alloc->Sym('raise'), \&raise, is_operative => true ),
            '^PID'   => $alloc->Procedure( $alloc->Sym('^PID'),  \&_pid,  is_operative => true ),
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
        my sub _print ($C, $E, @args) {
            return Slight::Machine::Host($E, $self, $alloc->Sym('print')),
                   Slight::Machine::EvalArgs($E, $alloc->List(@args))
        }

        my sub _warn ($C, $E, @args) {
            return Slight::Machine::Host($E, $self, $alloc->Sym('warn')),
                   Slight::Machine::EvalArgs($E, $alloc->List(@args))
        }

        my sub _say ($C, $E, @args) {
            return Slight::Machine::Host($E, $self, $alloc->Sym('say')),
                   Slight::Machine::EvalArgs($E, $alloc->List(@args))
        }

        my sub _readline ($C, $E) { return Slight::Machine::Host($E, $self, $alloc->Sym('readline')) }

        return +{
            'print'    => $alloc->Procedure( $alloc->Sym('print'   ), \&_print,    is_operative => true ),
            'say'      => $alloc->Procedure( $alloc->Sym('say'     ), \&_say,      is_operative => true ),
            'warn'     => $alloc->Procedure( $alloc->Sym('warn'    ), \&_warn,     is_operative => true ),
            'readline' => $alloc->Procedure( $alloc->Sym('readline'), \&_readline, is_operative => true ),
        }
    }
}
