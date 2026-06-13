
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight::Allocator;
use Slight::Context;
use Slight::Kontinue;
use Slight::Parser;
use Slight::Term;
use Slight::Timers;

class Slight::Host::Letter {
    # XXX - consider making this a proper Term
    use overload '""' => 'to_string';
    field $from :reader :param;
    field $to   :reader :param;
    field $msg  :reader :param;
    method to_string {
        sprintf 'msg(from: %s, to: %s, msg: %s)' => $from, $to, $msg;
    }
}

class Slight::Host::RunQueue {
    use constant READY   => 'READY';
    use constant BLOCKED => 'BLOCKED';
    use constant WAITING => 'WAITING';
    use constant HALTED  => 'HALTED';

    field %status;
    field %registry;

    method lookup   ($pid) { $registry{$pid->raw} }
    method register ($ctx) {
        $registry{$ctx->pid->raw} = $ctx;
        $self->set_to_ready($ctx);
    }

    # ...

    method running { grep $self->is_ready($_),   values %registry }
    method waiting { grep $self->is_waiting($_), values %registry }
    method blocked { grep $self->is_blocked($_), values %registry }
    method halted  { grep $self->is_halted($_),  values %registry }

    # ...

    method set_to_ready   ($ctx) { $status{$ctx->pid->raw} = READY }
    method set_to_blocked ($ctx) { $status{$ctx->pid->raw} = BLOCKED }
    method set_to_waiting ($ctx) { $status{$ctx->pid->raw} = WAITING }
    method set_to_halted  ($ctx) { $status{$ctx->pid->raw} = HALTED  }

    method is_ready   ($ctx) { $status{$ctx->pid->raw} eq READY   }
    method is_blocked ($ctx) { $status{$ctx->pid->raw} eq BLOCKED }
    method is_waiting ($ctx) { $status{$ctx->pid->raw} eq WAITING }
    method is_halted  ($ctx) { $status{$ctx->pid->raw} eq HALTED  }
}

class Slight::Host {
    use constant DEBUG => !!$ENV{DEBUG_HOST};

    field $alloc     :reader :param;
    field $root_env  :reader :param;
    field $timers    :reader :param;
    field $rqueue    :reader;

    field %mailboxes    :reader; # PID -> Slight::Host::Letter[]
    field @dead_letters :reader; # Slight::Host::Letter[]

    field %is_waiting :reader;
    field %to_watch   :reader;

    ADJUST {
        $rqueue = Slight::Host::RunQueue->new;
    }

    method lookup_pid ($pid) { $rqueue->lookup($pid) }

    method enqueue_message ($from, $to, $msg) {
        push $mailboxes{ $to->raw }->@* => Slight::Host::Letter->new(
            from => $from, to => $to, msg => $msg
        )
    }

    method dequeue_message ($for) {
        shift $mailboxes{ $for->raw }->@*;
    }

    method discard_message ($from, $to, $msg) {
        push @dead_letters => Slight::Host::Letter->new(
            from => $from, to => $to, msg => $msg
        )
    }

    method assemble ($env, @exprs) {
        return +[
            Slight::Kontinue::Halt->new( env => $env ),
            (reverse map {
                Slight::Kontinue::Drop->new( env => $env ),
                Slight::Kontinue::Eval::Expr->new( env => $env, expr => $_ )
            } @exprs),
        ];
    }

    method run {
        while (true) {
            while (my @to_be_run = $rqueue->running) {
                DEBUG && say "GOT TO RUN: ", join ', ' => @to_be_run;
                foreach my $ctx (@to_be_run) {
                    $timers->tick;
                    DEBUG && say "RUNNING: $ctx";
                    my $kont = $ctx->run_until_host;
                    $kont->HANDLE( $self, $ctx );
                }
            }
            DEBUG && say "??? NO MORE WORK, CHECKING FOR TIMERS?";
            if ($timers->has_active_timers) {
                if (my $wait = $timers->should_wait) {
                    DEBUG && say "@@ SNOOZE for $wait";
                    $timers->snooze( $wait );
                }
            } else {
                DEBUG && say "~~~ EXITING LOOP";
                last;
            }
        }
        return $rqueue;
    }

    method schedule_timer ($timeout, $ctx) {
        DEBUG && say "schedule( $timeout, $ctx )";
        my $timer = Slight::Timers::Timer->new(
            timeout  => $timeout,
            callback => $ctx,
        );
        $timers->schedule_timer($timer);
        return $timer;
    }

    method spawn_context ($exprs, $parent=undef) {
        state $PID_SEQ = 0;

        my $ctx = Slight::Context->new(
            pid    => $alloc->PID(++$PID_SEQ),
            alloc  => $alloc,
        );
        $ctx->enqueue( @$exprs );

        DEBUG && say ">> ^^ SPAWN ${ctx}";
        $mailboxes{ $ctx->pid->raw } = +[];

        $rqueue->register( $ctx );
        return $ctx;
    }

    method block ($ctx) {
        DEBUG && say ">> !! BLOCKING ${ctx}";
        $rqueue->set_to_blocked( $ctx );
    }

    method resume ($ctx) {
        DEBUG && say ">> !! CONTINUING ${ctx}";
        $rqueue->set_to_ready( $ctx );
    }

    method wait_for ($ctx, @pids) {
        DEBUG && say ">> !! WAITING ${ctx} FOR ", join ', ' => @pids;
        my $waiting_for = $is_waiting{$ctx->pid->raw} //= +{};
        foreach my $pid (@pids) {
            push @{ $to_watch{$pid->raw} //= +[] } => $ctx;
            $waiting_for->{$pid->raw}++;
        }
    }

    method halt ($ctx) {
        DEBUG && say ">> !! HALTING ${ctx}";
        $rqueue->set_to_halted( $ctx );

        if (my $watchers = delete $to_watch{$ctx->pid->raw}) {
            foreach my $watcher (@$watchers) {
                delete $is_waiting{$watcher->pid->raw}->{$ctx->pid->raw};
                if (scalar keys $is_waiting{$watcher->pid->raw}->%* == 0) {
                    delete $is_waiting{$watcher->pid->raw};
                    $self->resume($watcher);
                }
            }
        }
    }
}



