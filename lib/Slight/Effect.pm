
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
    method handler  ($i, $a, $e, @a) { ... }
    method provides { +{} }
    method to_string { sprintf '*{%s}' => __CLASS__ }
}

class Slight::Effect::HALT  :isa(Slight::Effect) {}
class Slight::Effect::ERROR :isa(Slight::Effect) {}

class Slight::Effect::TTY :isa(Slight::Effect) {
    field $alloc  :param :reader;
    field $input  :param :reader = \*STDIN;
    field $output :param :reader = \*STDOUT;
    field $error  :param :reader = \*STDERR;

    method handler  ($inter, $action, $env, @args) {
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
