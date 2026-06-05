
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
use Slight::WorkingMemory;

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

class Slight::Host {
    use constant DEBUG => !!$ENV{DEBUG_HOST};

    field $alloc     :reader :param;
    field $root_env  :reader :param;
    field $timers    :reader :param;

    field @running   :reader;
    field @blocked   :reader;
    field @halted    :reader;
    field %lookup    :reader;

    field %mailboxes    :reader; # PID -> Slight::Host::Letter[]
    field @dead_letters :reader; # Slight::Host::Letter[]

    our $PID_SEQ = 0;

    method lookup_pid ($pid) { $lookup{ $pid->raw } }

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
            while (@running) {
                $timers->tick;
                my $ctx  = shift @running;
                my $kont = $ctx->run_until_host;
                $kont->HANDLE( $self, $ctx );
            }
            if (my $wait = $timers->should_wait) {
                $timers->snooze( $wait );
            } else {
                last;
            }
        }
        return @halted;
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

    method spawn_context ($exprs) {
        my $ctx = Slight::Context->new(
            pid    => $alloc->PID(++$PID_SEQ),
            alloc  => $alloc,
            memory => Slight::WorkingMemory->new( alloc => $alloc )
        );
        $ctx->enqueue( @$exprs );
        $mailboxes{ $ctx->pid->raw } = +[];
        $lookup{ $ctx->pid->raw } = $ctx;
        push @running => $ctx;
        DEBUG && say ">> ^^ SPAWN ${ctx}";
        return $ctx;
    }

    method block ($ctx) {
        # return if already blocked
        return if grep { $ctx->pid->raw == $_->pid->raw } @blocked;
        DEBUG && say ">> !! BLOCKING ${ctx}";
        push @blocked => $ctx;
    }

    method kontinue ($ctx) {
        # return if already running
        return if grep { $ctx->pid->raw == $_->pid->raw } @running;
        DEBUG && say ">> !! CONTINUING ${ctx}";
        push @running => $ctx;
    }

    method halt ($ctx) {
        # return if already removed from lookup
        return if not exists $lookup{ $ctx->pid->raw };
        DEBUG && say ">> !! HALTING ${ctx}";
        push @halted => $ctx;
        delete $lookup{ $ctx->pid->raw };
    }

    method unblock ($ctx) {
        DEBUG && say ">> !! UNBLOCKING ${ctx}";
        @blocked = grep { $ctx->pid->raw != $_->pid->raw } @blocked;
        $self->kontinue($ctx);
    }
}



