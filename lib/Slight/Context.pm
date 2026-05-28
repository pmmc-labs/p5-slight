
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight::Kontinue;

class Slight::Context {
    use overload '""' => 'to_string';

    use constant DEBUG => !!$ENV{DEBUG_CTX};

    field $pid   :param :reader;
    field $alloc :param :reader;

    field @queue :reader;
    field @trace :reader;

    method derive_env ($env, %local) {
        return $alloc->Env( $env, %local );
    }

    method bind_variable ($env, $sym, $value) {
        return $alloc->Env( $env, $sym->raw, $value );
    }

    method thread_computation ($env, @stack) {
        my $tos = $queue[-1];
        $tos->THREAD( $env );
        $tos->PUSH( @stack );
        return ();
    }

    method enqueue (@q) { push @queue => @q }

    method run_until_host {
        return $trace[0] unless @queue;
        while (@queue) {
            my $next = pop @queue;
            unshift @trace => $next;
            DEBUG && say sprintf ' STEP[%03d]: %s' => $pid, $next;
            return $next if $next isa Slight::Kontinue::HOST;
            push @queue => $next->STEP( $self );
        }
        die "You fell of the edge of the world, this should not happen!";
    }

    method to_string {
        sprintf 'Ctx(Pid:%03d)' => $pid->raw;
    }
}
